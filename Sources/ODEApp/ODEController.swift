import SwiftUI
import CoreAudio
import ODEKit

/// Observable state bridging the SwiftUI panel to the ODE engine.
///
/// ODE has two independent denoising paths, each gated on real device usage so
/// nothing is captured/played until an app actually uses the virtual device:
///
///  • "Cancel my noise"     — capture your real mic, denoise, output to the
///                            "ODE Microphone" device that call apps read.
///  • "Cancel others' noise"— capture incoming audio an app plays into the
///                            "ODE Speaker" device, denoise, play to your real
///                            speakers/headphones.
///
/// Each toggle is only a *setting*; audio passes through (raw) when its toggle
/// is off, and is denoised when on — turning a toggle off never silences audio.
final class ODEController: ObservableObject {
    // Mic path ("cancel my noise")
    @Published var micEnabled = false
    @Published var micActive = false
    @Published var inputDevices: [AudioDevices.Device] = []
    @Published var selectedInputID: AudioDeviceID?

    // Speaker path ("cancel others' noise")
    @Published var speakerEnabled = false
    @Published var speakerActive = false
    @Published var outputDevices: [AudioDevices.Device] = []
    @Published var selectedOutputID: AudioDeviceID?

    // Transcription
    @Published var transcribeEnabled = false
    @Published var transcribing = false

    // Live audio levels (0...1) for the meters.
    @Published var micLevel: Float = 0
    @Published var othersLevel: Float = 0

    private let micEngine = LiveEngine()
    private let speakerEngine = LiveEngine()
    private var micObserver: AudioDevices.UsageObserver?
    private var speakerObserver: AudioDevices.UsageObserver?
    private var hardwareObservers: [AudioDevices.HardwareObserver] = []
    private var pendingHardwareChange: DispatchWorkItem?
    private var levelTimer: Timer?
    private var visibilityTimer: Timer?

    private var meetingTranscriber: Any?  // MeetingTranscriber (macOS 26+)

    init() {
        // Restore persisted settings before wiring anything up.
        let d = UserDefaults.standard
        micEnabled = d.object(forKey: Keys.micEnabled) as? Bool ?? false
        speakerEnabled = d.object(forKey: Keys.speakerEnabled) as? Bool ?? false
        transcribeEnabled = d.object(forKey: Keys.transcribeEnabled) as? Bool ?? false

        // The virtual devices are hidden while ODE isn't running, so users
        // never see a dead device in pickers. Show them now, and keep pinging
        // the driver (it auto-hides ~15 s after the pings stop — crash safety).
        showVirtualDevices()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.showVirtualDevices()
        }

        refreshDevices()
        // Prefer a remembered device (by UID, since IDs change across reboots).
        selectedInputID = rememberedDevice(uidKey: Keys.inputUID, in: inputDevices)?.id
            ?? preferredInputDevice()?.id
        selectedOutputID = rememberedDevice(uidKey: Keys.outputUID, in: outputDevices)?.id
            ?? preferredOutputDevice()?.id

        micEngine.bypassDenoise = !micEnabled
        speakerEngine.bypassDenoise = !speakerEnabled

        installObservers()
        installHardwareObservers()

        // When a device unplugs or its sample rate changes mid-call, the
        // engines stop themselves. Restart the affected path so audio comes
        // back instead of silently dying while the UI still shows "Active".
        micEngine.onConfigurationChange = { [weak self] in
            DispatchQueue.main.async { self?.restartMicPath() }
        }
        speakerEngine.onConfigurationChange = { [weak self] in
            DispatchQueue.main.async { self?.restartSpeakerPath() }
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.micLevel = self.micActive ? self.micEngine.currentLevel : 0
            self.othersLevel = self.speakerActive ? self.speakerEngine.currentLevel : 0
        }
    }

    // MARK: - Settings persistence

    private enum Keys {
        static let micEnabled = "ode.micEnabled"
        static let speakerEnabled = "ode.speakerEnabled"
        static let transcribeEnabled = "ode.transcribeEnabled"
        static let inputUID = "ode.inputUID"
        static let outputUID = "ode.outputUID"
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(micEnabled, forKey: Keys.micEnabled)
        d.set(speakerEnabled, forKey: Keys.speakerEnabled)
        d.set(transcribeEnabled, forKey: Keys.transcribeEnabled)
        if let u = selectedInput?.uid { d.set(u, forKey: Keys.inputUID) }
        if let u = selectedOutput?.uid { d.set(u, forKey: Keys.outputUID) }
    }

    private func rememberedDevice(uidKey: String, in list: [AudioDevices.Device]) -> AudioDevices.Device? {
        guard let uid = UserDefaults.standard.string(forKey: uidKey) else { return nil }
        return list.first { $0.uid == uid }
    }

    // MARK: - Master toggle

    /// True when either path is enabled (the header switch).
    var masterOn: Bool { micEnabled || speakerEnabled }

    /// Active = at least one path is currently processing a call.
    var anyActive: Bool { micActive || speakerActive }

    func toggleMaster() {
        let turnOn = !masterOn
        micEnabled = turnOn
        speakerEnabled = turnOn
        micEngine.bypassDenoise = !micEnabled
        speakerEngine.bypassDenoise = !speakerEnabled
        persistSettings()
        reconcileMic()
        reconcileSpeaker()
    }

    deinit {
        levelTimer?.invalidate()
        visibilityTimer?.invalidate()
        if let o = micObserver { AudioDevices.removeUsageObserver(o) }
        if let o = speakerObserver { AudioDevices.removeUsageObserver(o) }
        hardwareObservers.forEach { AudioDevices.removeHardwareObserver($0) }
    }

    // MARK: - Hardware-change resilience

    /// React to device plug/unplug and default-device changes: refresh the
    /// pickers, re-resolve the virtual devices (their IDs change when
    /// coreaudiod restarts, leaving the old usage observers dead), and
    /// reconcile both paths. Debounced — these notifications come in bursts.
    private func installHardwareObservers() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        hardwareObservers = selectors.compactMap { sel in
            AudioDevices.addHardwareObserver(sel) { [weak self] in
                DispatchQueue.main.async { self?.scheduleHardwareChange() }
            }
        }
    }

    private func scheduleHardwareChange() {
        pendingHardwareChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleHardwareChange() }
        pendingHardwareChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleHardwareChange() {
        refreshDevices()
        installObservers()
        // If a path's engine died with the device change (or its device
        // vanished), stop it so reconcile can start it again cleanly.
        if micActive && !micEngine.isHealthy { micEngine.stop(); micActive = false }
        if speakerActive && !speakerEngine.isHealthy { speakerEngine.stop(); speakerActive = false }
        reconcileMic()
        reconcileSpeaker()
    }

    /// Restart a path after its engine stopped itself (configuration change).
    private func restartMicPath() {
        guard micActive else { return }
        micEngine.stop()
        micActive = false
        refreshDevices()
        reconcileMic()
    }

    private func restartSpeakerPath() {
        guard speakerActive else { return }
        speakerEngine.stop()
        speakerActive = false
        refreshDevices()
        reconcileSpeaker()
    }

    // MARK: - Virtual devices

    /// CoreAudio UIDs of the four ODE devices (two per driver). UIDs are
    /// stable across reboots and resolve even while a device is hidden.
    private enum VirtualUID {
        static let mic = "ODE-Mic2ch_UID"
        static let micFeed = "ODE-Mic2ch_2_UID"
        static let speaker = "ODE-Spk2ch_UID"
        static let speakerTap = "ODE-Spk2ch_2_UID"
    }

    /// Visible "ODE Microphone" (input-only). Apps select it as their mic; ODE
    /// watches it for usage. ODE feeds audio via the hidden "ODE Mic Feed".
    /// Resolved by UID: the device is hidden until `showVirtualDevices()` ran,
    /// and hidden devices don't appear in name scans.
    var virtualMic: AudioDevices.Device? {
        AudioDevices.findByUID(VirtualUID.mic)
    }

    /// Hidden output device that backs ODE Microphone. ODE writes denoised
    /// voice here; it flows to the visible mic's input behind the scenes.
    var micFeed: AudioDevices.Device? {
        AudioDevices.findByUID(VirtualUID.micFeed)
    }

    /// Visible "ODE Speaker" (output-only). Apps select it as their speaker; ODE
    /// watches it for usage and reads the audio via the hidden "ODE Spk Tap".
    var virtualSpeaker: AudioDevices.Device? {
        AudioDevices.findByUID(VirtualUID.speaker)
    }

    /// Hidden input device that backs ODE Speaker. ODE reads incoming call
    /// audio here, denoises it, and plays it to your real output.
    var speakerTap: AudioDevices.Device? {
        AudioDevices.findByUID(VirtualUID.speakerTap)
    }

    /// Make the visible ODE devices appear in system device lists. Also serves
    /// as the driver heartbeat — called every 5 s while the app runs.
    private func showVirtualDevices() {
        AudioDevices.setVisible(true, uid: VirtualUID.mic)
        AudioDevices.setVisible(true, uid: VirtualUID.speaker)
    }

    /// Hide the ODE devices from system device lists (called on quit, so users
    /// never see a dead device while ODE isn't running).
    func hideVirtualDevices() {
        AudioDevices.setVisible(false, uid: VirtualUID.mic)
        AudioDevices.setVisible(false, uid: VirtualUID.speaker)
    }

    var virtualMicInstalled: Bool { virtualMic != nil }
    var virtualSpeakerInstalled: Bool { virtualSpeaker != nil }

    var selectedInput: AudioDevices.Device? { inputDevices.first { $0.id == selectedInputID } }
    var selectedOutput: AudioDevices.Device? { outputDevices.first { $0.id == selectedOutputID } }

    /// Combined status across both denoising paths for the header.
    var statusText: String {
        if !virtualMicInstalled && !virtualSpeakerInstalled {
            return "Install ODE devices to begin"
        }
        let anyEnabled = micEnabled || speakerEnabled
        let denoisingNow = (micActive && micEnabled) || (speakerActive && speakerEnabled)
        let passthroughNow = (micActive && !micEnabled) || (speakerActive && !speakerEnabled)

        if denoisingNow { return "Removing noise" }
        if passthroughNow { return "Passing through" }
        if anyEnabled { return "On · waiting for a call" }
        return "Off"
    }

    // MARK: - Device lists

    func refreshDevices() {
        let all = AudioDevices.all().filter { !$0.isHidden && !isLoopback($0) }
        inputDevices = all.filter { $0.hasInput }
        outputDevices = all.filter { $0.hasOutput }
        if selectedInputID == nil || !inputDevices.contains(where: { $0.id == selectedInputID }) {
            selectedInputID = preferredInputDevice()?.id
        }
        if selectedOutputID == nil || !outputDevices.contains(where: { $0.id == selectedOutputID }) {
            selectedOutputID = preferredOutputDevice()?.id
        }
    }

    // MARK: - Toggles

    func toggleMic() {
        micEnabled.toggle()
        micEngine.bypassDenoise = !micEnabled
        persistSettings()
        reconcileMic()
    }

    func toggleSpeaker() {
        speakerEnabled.toggle()
        speakerEngine.bypassDenoise = !speakerEnabled
        persistSettings()
        reconcileSpeaker()
    }

    func toggleTranscribe() {
        transcribeEnabled.toggle()
        persistSettings()
        reconcileTranscription()
    }

    func selectInput(_ id: AudioDeviceID) {
        selectedInputID = id
        if micActive { micEngine.stop(); micActive = false }
        persistSettings()
        reconcileMic()
    }

    func selectOutput(_ id: AudioDeviceID) {
        selectedOutputID = id
        if speakerActive { speakerEngine.stop(); speakerActive = false }
        persistSettings()
        reconcileSpeaker()
    }

    func stopIfRunning() {
        if micActive { micEngine.stop(); micActive = false }
        if speakerActive { speakerEngine.stop(); speakerActive = false }
    }

    // MARK: - Usage gating

    private func installObservers() {
        if let o = micObserver { AudioDevices.removeUsageObserver(o); micObserver = nil }
        if let o = speakerObserver { AudioDevices.removeUsageObserver(o); speakerObserver = nil }

        if let mic = virtualMic {
            micObserver = AudioDevices.addUsageObserver(
                mic.id, readScope: kAudioObjectPropertyScopeInput) { [weak self] _ in
                DispatchQueue.main.async { self?.reconcileMic() }
            }
        }
        if let spk = virtualSpeaker {
            speakerObserver = AudioDevices.addUsageObserver(
                spk.id, readScope: kAudioObjectPropertyScopeOutput) { [weak self] _ in
                DispatchQueue.main.async { self?.reconcileSpeaker() }
            }
        }
    }

    /// Mic path runs whenever an app reads the ODE Microphone. ODE captures the
    /// real mic, denoises, and writes to the hidden "ODE Mic Feed" — which the
    /// visible input-only ODE Microphone exposes to the app.
    private func reconcileMic() {
        guard let mic = virtualMic else { return }
        let inUse = AudioDevices.isInputInUse(mic.id)
        if inUse && !micActive {
            guard let input = selectedInput,
                  let feed = micFeed, input.id != feed.id else { return }
            do {
                try micEngine.start(inputDevice: input, outputDevice: feed, bypass: !micEnabled)
                micActive = true
            } catch {
                micActive = false
                NSLog("ODE: mic engine failed: \(error.localizedDescription)")
            }
        } else if !inUse && micActive {
            micEngine.stop(); micActive = false
        } else if micActive {
            micEngine.bypassDenoise = !micEnabled
        }
        reconcileTranscription()
    }

    /// Speaker path runs whenever an app plays into the ODE Speaker. ODE reads
    /// the incoming audio from the hidden "ODE Spk Tap", denoises it, and plays
    /// it to your real output device.
    private func reconcileSpeaker() {
        guard let spk = virtualSpeaker else { return }
        let inUse = AudioDevices.isOutputInUse(spk.id)
        if inUse && !speakerActive {
            guard let realOut = selectedOutput,
                  let tap = speakerTap, realOut.id != tap.id else { return }
            do {
                try speakerEngine.start(inputDevice: tap, outputDevice: realOut,
                                        bypass: !speakerEnabled)
                speakerActive = true
            } catch {
                speakerActive = false
                NSLog("ODE: speaker engine failed: \(error.localizedDescription)")
            }
        } else if !inUse && speakerActive {
            speakerEngine.stop(); speakerActive = false
        } else if speakerActive {
            speakerEngine.bypassDenoise = !speakerEnabled
        }
        reconcileTranscription()
    }

    // MARK: - Transcription

    /// Transcribe whenever the setting is on and a call is active on either path.
    private func reconcileTranscription() {
        guard #available(macOS 26.0, *) else { return }
        let inCall = micActive || speakerActive
        let shouldTranscribe = transcribeEnabled && inCall

        if shouldTranscribe && !transcribing {
            startTranscription()
        } else if !shouldTranscribe && transcribing {
            stopTranscription()
        }
    }

    @available(macOS 26.0, *)
    private func startTranscription() {
        let mt = MeetingTranscriber()
        meetingTranscriber = mt
        transcribing = true

        // Forward captured audio from each engine to the matching transcriber.
        micEngine.onCapturedAudio = { [weak mt] buf in mt?.feedMic(buf) }
        speakerEngine.onCapturedAudio = { [weak mt] buf in mt?.feedOthers(buf) }

        Task {
            do {
                try await MeetingTranscriber.ensureModel()
                try await mt.start()
            } catch {
                NSLog("ODE: transcription start failed: \(error.localizedDescription)")
                await MainActor.run { self.transcribing = false }
            }
        }
    }

    @available(macOS 26.0, *)
    private func stopTranscription() {
        transcribing = false
        micEngine.onCapturedAudio = nil
        speakerEngine.onCapturedAudio = nil
        guard let mt = meetingTranscriber as? MeetingTranscriber else { return }
        meetingTranscriber = nil
        Task {
            await mt.finishAndSave()
            await MainActor.run { self.objectWillChange.send() }
        }
    }

    // MARK: - Preferences

    private func preferredInputDevice() -> AudioDevices.Device? {
        if let def = AudioDevices.defaultInput(), !isLoopback(def), def.hasInput { return def }
        return inputDevices.first
    }

    private func preferredOutputDevice() -> AudioDevices.Device? {
        if let def = AudioDevices.defaultOutput(), !isLoopback(def), def.hasOutput { return def }
        return outputDevices.first
    }

    private func isLoopback(_ d: AudioDevices.Device) -> Bool {
        let n = d.name.lowercased()
        // Exclude all ODE virtual devices (visible + hidden feed/tap) and
        // BlackHole from the user-facing real-device pickers.
        return n.hasPrefix("ode ") || n.contains("blackhole")
    }
}
