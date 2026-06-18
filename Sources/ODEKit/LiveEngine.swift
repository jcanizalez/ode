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
/// the virtual "ODE Microphone" device.
public final class LiveEngine {
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let denoiser = Denoiser()
    private let ring = RingBuffer(capacity: 48_000 * 4) // 4 s headroom
    private var sourceNode: AVAudioSourceNode!

    /// When true, audio passes through untouched (no denoising). Can be flipped
    /// live while the engine runs — the audio keeps flowing either way.
    private var bypassLock = os_unfair_lock()
    private var _bypass = false
    public var bypassDenoise: Bool {
        get { os_unfair_lock_lock(&bypassLock); defer { os_unfair_lock_unlock(&bypassLock) }; return _bypass }
        set { os_unfair_lock_lock(&bypassLock); _bypass = newValue; os_unfair_lock_unlock(&bypassLock) }
    }

    public init() {}

    /// Optional sink for captured audio (post-resample, 48 kHz mono), used for
    /// transcription. Receives the same audio that is denoised/played.
    public var onCapturedAudio: ((AVAudioPCMBuffer) -> Void)?

    /// Start the loop. Captures from `inputDevice` (a real mic) and writes the
    /// denoised result to `outputDevice` (the virtual mic). Passing nil uses the
    /// system defaults. Guards against capturing from the same device we write
    /// to, which would create a feedback loop.
    public func start(inputDevice: AudioDevices.Device? = nil,
                      outputDevice: AudioDevices.Device?,
                      bypass: Bool = false) throws {
        bypassDenoise = bypass
        // Refuse to capture and play through the same device (feedback loop).
        if let inDev = inputDevice, let outDev = outputDevice, inDev.id == outDev.id {
            throw NSError(domain: "ode.live", code: -10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Input and output devices must differ (would cause a feedback loop)."])
        }

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
        if let inDev = inputDevice {
            try setInputDevice(captureEngine, deviceID: inDev.id)
        }
        let inFormat = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [denoiser, ring, weak self] buffer, _ in
            self?.onCapturedAudio?(buffer)
            let mono = AudioIO.resampleToMono48k(buffer)
            if self?.bypassDenoise == true {
                // Pass audio through untouched so the call still hears you,
                // just without noise removal.
                ring.write(mono)
            } else {
                let clean = denoiser.processStreaming(mono)
                if !clean.isEmpty { ring.write(clean) }
            }
        }

        captureEngine.prepare()
        playbackEngine.prepare()
        try playbackEngine.start()
        try captureEngine.start()
    }

    public func stop() {
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        _ = denoiser.flushStreaming()
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

    /// Route an AVAudioEngine's input to a specific CoreAudio device, so ODE
    /// always captures from a chosen real microphone rather than whatever the
    /// system default input happens to be (which could be the virtual mic).
    private func setInputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: "ode.live", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not set input device (OSStatus \(status))"])
        }
    }
}
