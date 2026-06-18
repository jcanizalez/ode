import AVFoundation

/// Captures audio from the default input device for a fixed duration,
/// returning 48 kHz mono float samples.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var collected: [Float] = []
    private let lock = NSLock()

    public init() {}

    public func record(seconds: Double) throws -> [Float] {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            let mono = AudioIO.resampleToMono48k(buffer)
            self.lock.lock()
            self.collected.append(contentsOf: mono)
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
        engine.stop()
        input.removeTap(onBus: 0)

        lock.lock(); defer { lock.unlock() }
        return collected
    }
}
