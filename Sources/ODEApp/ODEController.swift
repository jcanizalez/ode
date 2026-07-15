import SwiftUI
import CoreAudio
import ODEKit

extension Notification.Name {
    /// Posted when the hide-from-screen-capture setting changes so open
    /// windows re-apply their sharing policy immediately.
    static let odeCapturePolicyChanged = Notification.Name("odeCapturePolicyChanged")
}

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
    /// Acoustic echo cancellation on the mic path (Apple voice processing):
    /// without headphones, the mic otherwise re-captures whatever the
    /// speakers play — the remote side hears themselves and speaker audio
    /// bleeds into the "You" transcript.
    @Published var echoCancelEnabled = true
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
    @Published var asrEngine: TranscriptionEngine = .apple
    /// Sub-label remote participants as "Speaker 1/2/…" via diarization.
    @Published var detectSpeakers = false
    /// Exclude ODE's windows from screen sharing/recordings (you still see
    /// them; the audience doesn't).
    @Published var hideFromCapture = true
    /// 0...1 while an AI model is downloading, nil otherwise.
    @Published var modelDownloadProgress: Double?

    // Live audio levels (0...1) for the meters.
    @Published var micLevel: Float = 0
    @Published var othersLevel: Float = 0

    /// Mic engine is recreated when echo cancellation toggles (voice
    /// processing is fixed at engine creation — see LiveEngine.voiceProcessing).
    private var micEngine: LiveEngine
    private let speakerEngine = LiveEngine()
    /// Engine start/stop performs blocking CoreAudio calls (device pinning,
    /// TCC checks) that can stall for seconds. They run here so the main
    /// thread — and with it the UI and the device-visibility heartbeat —
    /// never freezes.
    private let engineQueue = DispatchQueue(label: "ode.engine", qos: .userInitiated)
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
        asrEngine = d.string(forKey: Keys.asrEngine)
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .apple
        detectSpeakers = d.object(forKey: Keys.detectSpeakers) as? Bool ?? false
        hideFromCapture = d.object(forKey: Keys.hideFromCapture) as? Bool ?? true
        let aec = d.object(forKey: Keys.echoCancel) as? Bool ?? true
        echoCancelEnabled = aec
        micEngine = LiveEngine(voiceProcessing: aec)

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
        micEngine.label = "mic"
        speakerEngine.label = "speaker"

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
        static let asrEngine = "ode.asrEngine"
        static let detectSpeakers = "ode.detectSpeakers"
        static let echoCancel = "ode.echoCancel"
        static let hideFromCapture = "ode.hideFromCapture"
        static let inputUID = "ode.inputUID"
        static let outputUID = "ode.outputUID"
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(micEnabled, forKey: Keys.micEnabled)
        d.set(speakerEnabled, forKey: Keys.speakerEnabled)
        d.set(transcribeEnabled, forKey: Keys.transcribeEnabled)
        d.set(asrEngine.rawValue, forKey: Keys.asrEngine)
        d.set(detectSpeakers, forKey: Keys.detectSpeakers)
        d.set(echoCancelEnabled, forKey: Keys.echoCancel)
        d.set(hideFromCapture, forKey: Keys.hideFromCapture)
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
        if micActive && !micEngine.isHealthy {
            micActive = false
            engineQueue.async { [micEngine] in micEngine.stop() }
        }
        if speakerActive && !speakerEngine.isHealthy {
            speakerActive = false
            engineQueue.async { [speakerEngine] in speakerEngine.stop() }
        }
        reconcileMic()
        reconcileSpeaker()
    }

    /// Restart a path after its engine stopped itself (configuration change).
    private func restartMicPath() {
        guard micActive else { return }
        micActive = false
        engineQueue.async { [micEngine] in micEngine.stop() }
        refreshDevices()
        reconcileMic()
    }

    private func restartSpeakerPath() {
        guard speakerActive else { return }
        speakerActive = false
        engineQueue.async { [speakerEngine] in speakerEngine.stop() }
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
        // Real hardware only: no hidden devices, no ODE/loopback drivers, and
        // no system plumbing (voice-processing aggregates, virtual devices
        // like "Microsoft Teams Audio").
        let all = AudioDevices.all().filter {
            !$0.isHidden && !isLoopback($0) && !$0.isSystemPlumbing
        }
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

    /// Switch speech-to-text engines. Applies to the *next* transcription
    /// session; one already in progress keeps its engine.
    func setEngine(_ engine: TranscriptionEngine) {
        guard engine != asrEngine else { return }
        asrEngine = engine
        persistSettings()
        if engine == .parakeet { prefetchParakeetModel() }
    }

    /// Toggle whether ODE's windows are excluded from screen capture.
    func toggleHideFromCapture() {
        hideFromCapture.toggle()
        persistSettings()
        NotificationCenter.default.post(name: .odeCapturePolicyChanged, object: nil)
    }

    /// Toggle acoustic echo cancellation. Voice processing is fixed per
    /// engine instance, so the mic engine is swapped for a new one (and the
    /// path restarts immediately when mid-call).
    func toggleEchoCancel() {
        echoCancelEnabled.toggle()
        persistSettings()

        let old = micEngine
        let wasActive = micActive
        micActive = false
        engineQueue.async { old.stop() }

        let fresh = LiveEngine(voiceProcessing: echoCancelEnabled)
        fresh.label = "mic"
        fresh.bypassDenoise = !micEnabled
        fresh.onCapturedAudio = old.onCapturedAudio   // keep transcription fed
        fresh.onConfigurationChange = { [weak self] in
            DispatchQueue.main.async { self?.restartMicPath() }
        }
        micEngine = fresh
        if wasActive { reconcileMic() }
    }

    /// Toggle "Speaker 1/2/…" sub-labels for remote participants. Applies to
    /// the next transcription session; prefetches the diarization model.
    func toggleDetectSpeakers() {
        detectSpeakers.toggle()
        persistSettings()
        if detectSpeakers {
            prefetchModel { try await SpeakerDiarizer.ensureModel(progress: $0) }
        }
    }

    /// Download the Parakeet model in the background the moment the user picks
    /// the engine, with visible progress — instead of stalling silently at the
    /// start of their first transcribed meeting.
    private func prefetchParakeetModel() {
        guard !ParakeetStreamTranscriber.modelIsCached else { return }
        prefetchModel { try await ParakeetStreamTranscriber.ensureModel(progress: $0) }
    }

    private func prefetchModel(
        _ ensure: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        guard modelDownloadProgress == nil else { return }
        modelDownloadProgress = 0
        Task {
            do {
                try await ensure { fraction in
                    DispatchQueue.main.async { [weak self] in
                        // ensureModel also reports model-compile progress on
                        // later runs; only surface it while actually fetching.
                        if self?.modelDownloadProgress != nil {
                            self?.modelDownloadProgress = fraction
                        }
                    }
                }
            } catch {
                NSLog("ODE: model download failed: \(error.localizedDescription)")
            }
            await MainActor.run { self.modelDownloadProgress = nil }
        }
    }

    func selectInput(_ id: AudioDeviceID) {
        selectedInputID = id
        if micActive {
            micActive = false
            engineQueue.async { [micEngine] in micEngine.stop() }
        }
        persistSettings()
        reconcileMic()
    }

    func selectOutput(_ id: AudioDeviceID) {
        selectedOutputID = id
        if speakerActive {
            speakerActive = false
            engineQueue.async { [speakerEngine] in speakerEngine.stop() }
        }
        persistSettings()
        reconcileSpeaker()
    }

    func stopIfRunning() {
        if micActive {
            micActive = false
            engineQueue.async { [micEngine] in micEngine.stop() }
        }
        if speakerActive {
            speakerActive = false
            engineQueue.async { [speakerEngine] in speakerEngine.stop() }
        }
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
            if selectedInput == nil { refreshDevices() }  // device vanished — fall back
            guard let input = selectedInput,
                  let feed = micFeed, input.id != feed.id else { return }
            micActive = true  // optimistic; cleared if start fails
            let bypass = !micEnabled
            engineQueue.async { [weak self, micEngine] in
                do {
                    try micEngine.start(inputDevice: input, outputDevice: feed,
                                        bypass: bypass)
                } catch {
                    LiveEngine.diagnostic("[mic] START FAILED: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.micActive = false
                        // Retry while the call is still using the device — a
                        // transient HAL failure must not mute a whole meeting.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.reconcileMic()
                        }
                    }
                }
            }
        } else if !inUse && micActive {
            micActive = false
            engineQueue.async { [micEngine] in micEngine.stop() }
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
            if selectedOutput == nil { refreshDevices() }  // device vanished — fall back
            guard let realOut = selectedOutput,
                  let tap = speakerTap, realOut.id != tap.id else { return }
            speakerActive = true  // optimistic; cleared if start fails
            let bypass = !speakerEnabled
            engineQueue.async { [weak self, speakerEngine] in
                do {
                    try speakerEngine.start(inputDevice: tap, outputDevice: realOut,
                                            bypass: bypass)
                } catch {
                    LiveEngine.diagnostic("[speaker] START FAILED: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.speakerActive = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.reconcileSpeaker()
                        }
                    }
                }
            }
        } else if !inUse && speakerActive {
            speakerActive = false
            engineQueue.async { [speakerEngine] in speakerEngine.stop() }
        } else if speakerActive {
            speakerEngine.bypassDenoise = !speakerEnabled
        }
        reconcileTranscription()
    }

    /// Finish and persist any in-progress transcription, then call
    /// `completion` (arbitrary thread). The quit path uses this so an active
    /// meeting's transcript is saved instead of silently dropped.
    func finishTranscription(completion: @escaping () -> Void) {
        guard #available(macOS 26.0, *), transcribing,
              let mt = meetingTranscriber as? MeetingTranscriber else {
            completion()
            return
        }
        transcribing = false
        micEngine.onCapturedAudio = nil
        speakerEngine.onCapturedAudio = nil
        meetingTranscriber = nil
        Task {
            await mt.finishAndSave()
            completion()
        }
    }

    // MARK: - Meetings badge

    /// Meetings saved since the user last opened the Meetings window —
    /// the panel's "you have new notes" badge. Cleared by markMeetingsOpened.
    func newMeetingsCount() -> Int {
        let last = UserDefaults.standard.object(forKey: "ode.meetingsLastOpened") as? Date
            ?? .distantPast
        return TranscriptStore.shared.load().filter { $0.endedAt > last }.count
    }

    func markMeetingsOpened() {
        UserDefaults.standard.set(Date(), forKey: "ode.meetingsLastOpened")
    }

    // MARK: - Live meeting access

    /// Snapshot of the meeting currently being transcribed (nil when none).
    var liveMeeting: Transcript? {
        guard #available(macOS 26.0, *),
              let mt = meetingTranscriber as? MeetingTranscriber else { return nil }
        return mt.liveSnapshot()
    }

    /// Attach a live Q&A exchange to the in-progress meeting so it's saved
    /// with the transcript when the meeting ends.
    func recordLiveChat(question: String, answer: String) {
        guard #available(macOS 26.0, *),
              let mt = meetingTranscriber as? MeetingTranscriber else { return }
        mt.recordChat(question: question, answer: answer)
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
        let engine = asrEngine
        let diarize = detectSpeakers
        let mt = MeetingTranscriber(engine: engine, detectSpeakers: diarize)
        meetingTranscriber = mt
        transcribing = true

        // Meeting context: which app is calling, and what the calendar says
        // is happening right now (titles the transcript "Sprint Planning"
        // instead of "11:09 AM Meeting").
        mt.sourceApp = SourceAppDetector.detect()
        Task { [weak mt] in
            if await CalendarMeetings.ensureAccess(),
               let meeting = CalendarMeetings.currentEvent() {
                mt?.suggestedTitle = meeting.title
                mt?.attendees = meeting.attendeeFirstNames.isEmpty
                    ? nil : meeting.attendeeFirstNames
            }
        }

        // Forward captured audio from each engine to the matching transcriber.
        micEngine.onCapturedAudio = { [weak mt] buf in mt?.feedMic(buf) }
        speakerEngine.onCapturedAudio = { [weak mt] buf in mt?.feedOthers(buf) }

        Task {
            do {
                try await MeetingTranscriber.ensureModel(engine: engine, detectSpeakers: diarize)
                try await mt.start()
            } catch {
                NSLog("ODE: transcription start failed: \(error.localizedDescription)")
                await MainActor.run { self.transcribing = false }
            }
        }
    }

    /// First name for AI attribution/mentions: user override, else the
    /// macOS account's full name — the on-device "account info".
    private var userFirstName: String {
        let name = UserDefaults.standard.string(forKey: "ode.userName")
            .flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    @available(macOS 26.0, *)
    private func stopTranscription() {
        transcribing = false
        micEngine.onCapturedAudio = nil
        speakerEngine.onCapturedAudio = nil
        guard let mt = meetingTranscriber as? MeetingTranscriber else { return }
        meetingTranscriber = nil
        let name = userFirstName
        Task {
            let saved = await mt.finishAndSave()
            await MainActor.run { self.objectWillChange.send() }
            // Auto-summarize: the notes are ready when the user opens them,
            // no button needed. Additive — failure leaves the raw transcript.
            if var t = saved, MeetingAI.isAvailable, MeetingNotesFormat.hasSubstance(t) {
                do {
                    let insights = try await MeetingAI.insights(for: t, userName: name)
                    t.summary = insights.summary
                    t.keyPoints = insights.keyPoints
                    t.actionItems = insights.actionItems
                    t.decisions = insights.decisions.isEmpty ? nil : insights.decisions
                    t.openQuestions = insights.openQuestions.isEmpty ? nil : insights.openQuestions
                    t.chapters = insights.chapters.isEmpty ? nil : insights.chapters
                    TranscriptStore.shared.save(t)
                } catch {
                    NSLog("ODE: auto-summarize failed: \(error.localizedDescription)")
                }
            }
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
