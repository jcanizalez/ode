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
    private var levelTimer: Timer?

    private var meetingTranscriber: Any?  // MeetingTranscriber (macOS 26+)

    init() {
        refreshDevices()
        selectedInputID = preferredInputDevice()?.id
        selectedOutputID = preferredOutputDevice()?.id
        installObservers()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.micLevel = self.micActive ? self.micEngine.currentLevel : 0
            self.othersLevel = self.speakerActive ? self.speakerEngine.currentLevel : 0
        }
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
        reconcileMic()
        reconcileSpeaker()
    }

    deinit {
        levelTimer?.invalidate()
        if let o = micObserver { AudioDevices.removeUsageObserver(o) }
        if let o = speakerObserver { AudioDevices.removeUsageObserver(o) }
    }

    // MARK: - Virtual devices

    /// "ODE Microphone": ODE writes denoised voice here; apps read it as a mic.
    var virtualMic: AudioDevices.Device? {
        AudioDevices.all().first {
            $0.hasOutput && $0.name.localizedCaseInsensitiveContains("ode microphone")
        } ?? AudioDevices.all().first {
            $0.hasOutput && $0.name.localizedCaseInsensitiveContains("blackhole")
        }
    }

    /// "ODE Speaker": apps play incoming audio here; ODE reads + denoises it.
    var virtualSpeaker: AudioDevices.Device? {
        AudioDevices.all().first {
            $0.hasInput && $0.name.localizedCaseInsensitiveContains("ode speaker")
        }
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
        inputDevices = AudioDevices.all().filter { $0.hasInput && !isLoopback($0) }
        outputDevices = AudioDevices.all().filter { $0.hasOutput && !isLoopback($0) }
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
        reconcileMic()
    }

    func toggleSpeaker() {
        speakerEnabled.toggle()
        speakerEngine.bypassDenoise = !speakerEnabled
        reconcileSpeaker()
    }

    func toggleTranscribe() {
        transcribeEnabled.toggle()
        reconcileTranscription()
    }

    func selectInput(_ id: AudioDeviceID) {
        selectedInputID = id
        if micActive { micEngine.stop(); micActive = false }
        reconcileMic()
    }

    func selectOutput(_ id: AudioDeviceID) {
        selectedOutputID = id
        if speakerActive { speakerEngine.stop(); speakerActive = false }
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

    /// Mic path runs whenever an app reads the ODE Microphone.
    private func reconcileMic() {
        guard let out = virtualMic else { return }
        let inUse = AudioDevices.isInputInUse(out.id)
        if inUse && !micActive {
            guard let input = selectedInput, input.id != out.id else { return }
            do {
                try micEngine.start(inputDevice: input, outputDevice: out, bypass: !micEnabled)
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

    /// Speaker path runs whenever an app plays into the ODE Speaker.
    private func reconcileSpeaker() {
        guard let spk = virtualSpeaker else { return }
        let inUse = AudioDevices.isOutputInUse(spk.id)
        if inUse && !speakerActive {
            guard let realOut = selectedOutput, realOut.id != spk.id else { return }
            do {
                // Capture from the ODE Speaker (what the app played in), denoise,
                // and play to your real speakers/headphones.
                try speakerEngine.start(inputDevice: spk, outputDevice: realOut,
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
        return n.contains("ode microphone") || n.contains("ode speaker")
            || n.contains("blackhole")
    }
}
