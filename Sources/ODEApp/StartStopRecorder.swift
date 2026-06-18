import AVFoundation
import ODEKit

/// Manual start/stop microphone recorder (unlike MicRecorder's fixed duration).
/// Captures 48 kHz mono float samples until `stop()` is called.
final class StartStopRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var isRecording = false

    func start() throws {
        lock.lock(); samples.removeAll(); lock.unlock()
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let mono = AudioIO.resampleToMono48k(buffer)
            self.lock.lock(); self.samples.append(contentsOf: mono); self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return current() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return current()
    }

    private func current() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
