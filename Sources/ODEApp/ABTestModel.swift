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
    @Published var isPlaying = false
    @Published var noiseReductionDB: Double = 0
    @Published var errorText: String?

    let sampleScript = "ODE removes background noise so people hear your voice "
        + "clearly. Read this line a few times while something is making noise nearby."

    private nonisolated(unsafe) let denoiser = Denoiser()
    private let recorder = StartStopRecorder()
    private var timer: Timer?
    private var startDate: Date?

    // Two synchronized infinite-loop players; we mute the inactive one so the
    // Off/On switch is instant and gap-free.
    private var originalPlayer: AVAudioPlayer?
    private var denoisedPlayer: AVAudioPlayer?
    private var rawURL: URL?
    private var cleanURL: URL?

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
            do {
                let tmp = FileManager.default.temporaryDirectory
                let r = tmp.appendingPathComponent("ode_ab_raw.wav")
                let c = tmp.appendingPathComponent("ode_ab_clean.wav")
                try AudioIO.writeWav(samples: raw, url: r)
                try AudioIO.writeWav(samples: clean, url: c)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rawURL = r; self.cleanURL = c
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
        [originalPlayer, denoisedPlayer].forEach {
            $0?.numberOfLoops = -1
            $0?.prepareToPlay()
        }
        applyMix()
    }

    /// Mute whichever player is not selected so switching is instantaneous.
    private func applyMix() {
        originalPlayer?.volume = useDenoised ? 0 : 1
        denoisedPlayer?.volume = useDenoised ? 1 : 0
    }

    func setUseDenoised(_ on: Bool) {
        useDenoised = on
        applyMix()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        guard let o = originalPlayer, let d = denoisedPlayer else { return }
        applyMix()
        // Start both at a common device time so their loops stay phase-aligned.
        let t = max(o.deviceCurrentTime, d.deviceCurrentTime) + 0.05
        o.play(atTime: t)
        d.play(atTime: t)
        isPlaying = true
    }

    private func pause() {
        originalPlayer?.pause()
        denoisedPlayer?.pause()
        isPlaying = false
    }

    func recordAgain() {
        pause()
        originalPlayer = nil
        denoisedPlayer = nil
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
