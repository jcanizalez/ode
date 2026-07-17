import SwiftUI
import AVFoundation
import ODEKit

/// Drives the three-step "Test how you'll sound" flow:
/// idle → recording → review (with a seamless before/after switch).
@MainActor
final class ABTestModel: ObservableObject {
    enum Phase { case idle, recording, processing, review }

    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var useDenoised = true       // the Off/On switch (On = with ODE)
    @Published var useStudio = false        // Studio Voice on top (either side)
    @Published var isPlaying = false
    @Published var noiseReductionDB: Double = 0
    @Published var errorText: String?

    let sampleScript = "ODE removes background noise so people hear your voice "
        + "clearly. Read this line a few times while something is making noise nearby."

    private nonisolated(unsafe) let denoiser = Denoiser()
    private let recorder = StartStopRecorder()
    private var timer: Timer?
    private var startDate: Date?

    // Four synchronized infinite-loop players (original/denoised × plain/
    // Studio Voice); we mute all but the selected one so the switches are
    // instant and gap-free.
    private var originalPlayer: AVAudioPlayer?
    private var denoisedPlayer: AVAudioPlayer?
    private var originalStudioPlayer: AVAudioPlayer?
    private var denoisedStudioPlayer: AVAudioPlayer?
    private var rawURL: URL?
    private var cleanURL: URL?
    private var rawStudioURL: URL?
    private var cleanStudioURL: URL?

    // MARK: - Recording

    func startRecording() {
        errorText = nil
        do {
            try recorder.start()
            phase = .recording
            elapsed = 0
            startDate = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func stopRecording() {
        timer?.invalidate(); timer = nil
        let raw = recorder.stop()
        guard raw.count > 480 else {
            errorText = "No audio captured. Check Microphone permission in "
                + "System Settings ▸ Privacy ▸ Microphone."
            phase = .idle
            return
        }
        phase = .processing
        let denoiser = self.denoiser
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let clean = denoiser.process(raw)
            let cut = Self.reductionDB(raw: raw, clean: clean)
            // Studio Voice variants of both sides, so the switch composes
            // with Off/On exactly like the live pipeline does. Fresh
            // instances: the chain is stateful.
            let rawStudio = StudioVoice().process(raw)
            let cleanStudio = StudioVoice().process(clean)
            do {
                let tmp = FileManager.default.temporaryDirectory
                let r = tmp.appendingPathComponent("ode_ab_raw.wav")
                let c = tmp.appendingPathComponent("ode_ab_clean.wav")
                let rs = tmp.appendingPathComponent("ode_ab_raw_studio.wav")
                let cs = tmp.appendingPathComponent("ode_ab_clean_studio.wav")
                try AudioIO.writeWav(samples: raw, url: r)
                try AudioIO.writeWav(samples: clean, url: c)
                try AudioIO.writeWav(samples: rawStudio, url: rs)
                try AudioIO.writeWav(samples: cleanStudio, url: cs)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rawURL = r; self.cleanURL = c
                    self.rawStudioURL = rs; self.cleanStudioURL = cs
                    self.noiseReductionDB = cut
                    self.preparePlayers()
                    self.phase = .review
                    self.useDenoised = true
                    self.play()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.errorText = error.localizedDescription
                    self.phase = .idle
                }
            }
        }
    }

    // MARK: - Playback

    private func preparePlayers() {
        guard let rawURL, let cleanURL else { return }
        originalPlayer = try? AVAudioPlayer(contentsOf: rawURL)
        denoisedPlayer = try? AVAudioPlayer(contentsOf: cleanURL)
        originalStudioPlayer = rawStudioURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        denoisedStudioPlayer = cleanStudioURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        allPlayers.forEach {
            $0.numberOfLoops = -1
            $0.prepareToPlay()
        }
        applyMix()
    }

    private var allPlayers: [AVAudioPlayer] {
        [originalPlayer, denoisedPlayer,
         originalStudioPlayer, denoisedStudioPlayer].compactMap { $0 }
    }

    /// The player matching the current switch state; everything else is muted.
    private var selectedPlayer: AVAudioPlayer? {
        switch (useDenoised, useStudio) {
        case (false, false): return originalPlayer
        case (true, false):  return denoisedPlayer
        case (false, true):  return originalStudioPlayer ?? originalPlayer
        case (true, true):   return denoisedStudioPlayer ?? denoisedPlayer
        }
    }

    /// Mute whichever players are not selected so switching is instantaneous.
    private func applyMix() {
        let selected = selectedPlayer
        allPlayers.forEach { $0.volume = $0 === selected ? 1 : 0 }
    }

    func setUseDenoised(_ on: Bool) {
        useDenoised = on
        applyMix()
    }

    func setUseStudio(_ on: Bool) {
        useStudio = on
        applyMix()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        let players = allPlayers
        guard !players.isEmpty else { return }
        applyMix()
        // Start all at a common device time so their loops stay phase-aligned.
        let t = (players.map(\.deviceCurrentTime).max() ?? 0) + 0.05
        players.forEach { $0.play(atTime: t) }
        isPlaying = true
    }

    private func pause() {
        allPlayers.forEach { $0.pause() }
        isPlaying = false
    }

    func recordAgain() {
        pause()
        originalPlayer = nil
        denoisedPlayer = nil
        originalStudioPlayer = nil
        denoisedStudioPlayer = nil
        elapsed = 0
        phase = .idle
    }

    func cleanup() {
        timer?.invalidate(); timer = nil
        pause()
    }

    // MARK: - Helpers

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private nonisolated static func reductionDB(raw: [Float], clean: [Float]) -> Double {
        func rms(_ s: [Float]) -> Double {
            guard !s.isEmpty else { return 0 }
            let acc = s.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (acc / Double(s.count)).squareRoot()
        }
        let r = rms(raw), c = rms(clean)
        guard r > 0, c > 0 else { return 0 }
        return 20 * log10(r / c)
    }
}
