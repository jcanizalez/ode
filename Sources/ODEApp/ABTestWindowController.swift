import AppKit
import AVFoundation
import ODEKit

/// "Test like Krisp" window: record a short clip, then hear it played back
/// with and without ODE denoising so the difference is obvious.
final class ABTestWindowController: NSWindowController {
    private let denoiser = Denoiser()

    private let statusLabel = NSTextField(labelWithString: "Record a clip, then compare.")
    private let recordButton = NSButton(title: "● Record", target: nil, action: nil)
    private let playOriginalButton = NSButton(title: "▶ Original (noisy)", target: nil, action: nil)
    private let playDenoisedButton = NSButton(title: "▶ With ODE (clean)", target: nil, action: nil)
    private let durationSlider = NSSlider(value: 30, minValue: 5, maxValue: 30, target: nil, action: nil)
    private let durationLabel = NSTextField(labelWithString: "30 s")

    private var rawURL: URL?
    private var cleanURL: URL?
    private var player: AVAudioPlayer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ODE — Before / After"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Test ODE noise removal")
        title.font = .boldSystemFont(ofSize: 15)

        durationSlider.target = self
        durationSlider.action = #selector(durationChanged)
        durationSlider.numberOfTickMarks = 6
        durationSlider.allowsTickMarkValuesOnly = false

        recordButton.target = self
        recordButton.action = #selector(record)
        recordButton.bezelStyle = .rounded

        playOriginalButton.target = self
        playOriginalButton.action = #selector(playOriginal)
        playOriginalButton.isEnabled = false

        playDenoisedButton.target = self
        playDenoisedButton.action = #selector(playDenoised)
        playDenoisedButton.isEnabled = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let durRow = NSStackView(views: [NSTextField(labelWithString: "Length:"),
                                         durationSlider, durationLabel])
        durRow.orientation = .horizontal
        durRow.spacing = 8

        let playRow = NSStackView(views: [playOriginalButton, playDenoisedButton])
        playRow.orientation = .horizontal
        playRow.distribution = .fillEqually
        playRow.spacing = 10

        let stack = NSStackView(views: [title, durRow, recordButton, playRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            playRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func durationChanged() {
        durationLabel.stringValue = "\(Int(durationSlider.doubleValue)) s"
    }

    // MARK: - Record + denoise

    @objc private func record() {
        let seconds = durationSlider.doubleValue
        setControls(enabled: false)
        statusLabel.stringValue = "Recording \(Int(seconds))s… speak now (add some background noise!)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let raw = try MicRecorder().record(seconds: seconds)
                guard !raw.isEmpty else {
                    self.finish(error: "No audio captured. Check Microphone permission in System Settings ▸ Privacy.")
                    return
                }
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Denoising \(raw.count) samples…"
                }
                let clean = self.denoiser.process(raw)

                let tmp = FileManager.default.temporaryDirectory
                let rURL = tmp.appendingPathComponent("ode_ab_raw.wav")
                let cURL = tmp.appendingPathComponent("ode_ab_clean.wav")
                try AudioIO.writeWav(samples: raw, url: rURL)
                try AudioIO.writeWav(samples: clean, url: cURL)

                let cut = self.noiseReductionDB(raw: raw, clean: clean)
                DispatchQueue.main.async {
                    self.rawURL = rURL
                    self.cleanURL = cURL
                    self.playOriginalButton.isEnabled = true
                    self.playDenoisedButton.isEnabled = true
                    self.setControls(enabled: true)
                    self.statusLabel.stringValue = String(
                        format: "Done. Compare the two below.  (≈ %.0f dB quieter overall)", cut)
                }
            } catch {
                self.finish(error: error.localizedDescription)
            }
        }
    }

    private func finish(error: String) {
        DispatchQueue.main.async {
            self.setControls(enabled: true)
            self.statusLabel.stringValue = "Error: \(error)"
        }
    }

    private func setControls(enabled: Bool) {
        recordButton.isEnabled = enabled
        durationSlider.isEnabled = enabled
    }

    /// Rough overall loudness reduction in dB (raw RMS vs clean RMS).
    private func noiseReductionDB(raw: [Float], clean: [Float]) -> Double {
        func rms(_ s: [Float]) -> Double {
            guard !s.isEmpty else { return 0 }
            let acc = s.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (acc / Double(s.count)).squareRoot()
        }
        let r = rms(raw), c = rms(clean)
        guard r > 0, c > 0 else { return 0 }
        return 20 * log10(r / c)
    }

    // MARK: - Playback

    @objc private func playOriginal() { play(url: rawURL, label: "Playing original (noisy)…") }
    @objc private func playDenoised() { play(url: cleanURL, label: "Playing with ODE (clean)…") }

    private func play(url: URL?, label: String) {
        guard let url else { return }
        player?.stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            statusLabel.stringValue = label
        } catch {
            statusLabel.stringValue = "Playback error: \(error.localizedDescription)"
        }
    }
}
