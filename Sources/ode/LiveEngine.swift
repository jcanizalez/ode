import AVFoundation
import CoreAudio

/// Simple thread-safe float ring buffer for passing audio between the
/// capture callback and the playback render callback.
final class RingBuffer {
    private var storage: [Float]
    private var readIdx = 0
    private var writeIdx = 0
    private var filled = 0
    private let lock = NSLock()

    init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }

    func write(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            storage[writeIdx] = s
            writeIdx = (writeIdx + 1) % storage.count
            if filled < storage.count {
                filled += 1
            } else {
                readIdx = (readIdx + 1) % storage.count // overwrite oldest
            }
        }
    }

    /// Fill `out` with up to `count` samples; pad with silence on underrun.
    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            if filled > 0 {
                out[i] = storage[readIdx]
                readIdx = (readIdx + 1) % storage.count
                filled -= 1
            } else {
                out[i] = 0
            }
        }
    }
}

/// Real-time loop: capture default mic -> denoise -> play to a target output
/// device (e.g. the virtual "ODE Microphone"). This is the streaming core that
/// makes ODE behave like Krisp.
final class LiveEngine {
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let denoiser = Denoiser()
    private let ring = RingBuffer(capacity: 48_000 * 4) // 4 s headroom
    private var sourceNode: AVAudioSourceNode!

    /// Start the loop. If `outputDevice` is nil, the system default output is used.
    func start(outputDevice: AudioDevices.Device?) throws {
        let fmt = AudioIO.monoFormat

        // --- Playback graph: source node pulls denoised audio from the ring ---
        sourceNode = AVAudioSourceNode(format: fmt) { [ring] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            if let ptr = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                ring.read(into: ptr, count: n)
            }
            return noErr
        }
        playbackEngine.attach(sourceNode)
        playbackEngine.connect(sourceNode, to: playbackEngine.mainMixerNode, format: fmt)

        if let dev = outputDevice {
            try setOutputDevice(playbackEngine, deviceID: dev.id)
        }

        // --- Capture graph: tap mic, denoise, push into the ring ---
        let input = captureEngine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [denoiser, ring] buffer, _ in
            let mono = AudioIO.resampleToMono48k(buffer)
            let clean = denoiser.processStreaming(mono)
            if !clean.isEmpty { ring.write(clean) }
        }

        captureEngine.prepare()
        playbackEngine.prepare()
        try playbackEngine.start()
        try captureEngine.start()
    }

    func stop() {
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        playbackEngine.stop()
    }

    /// Route an AVAudioEngine's output to a specific CoreAudio device.
    private func setOutputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { return }
        var dev = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: "ode.live", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not set output device (OSStatus \(status))"])
        }
    }
}
