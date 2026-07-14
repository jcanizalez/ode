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

    /// Drop all buffered audio (call between sessions to avoid stale playback).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        readIdx = 0; writeIdx = 0; filled = 0
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
    private var isRunning = false

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
    /// Lock-protected: it is set from the main thread while the audio tap
    /// thread reads it, and closure loads/stores are not atomic.
    private var capturedSinkLock = os_unfair_lock()
    private var _onCapturedAudio: ((AVAudioPCMBuffer) -> Void)?
    public var onCapturedAudio: ((AVAudioPCMBuffer) -> Void)? {
        get { os_unfair_lock_lock(&capturedSinkLock); defer { os_unfair_lock_unlock(&capturedSinkLock) }; return _onCapturedAudio }
        set { os_unfair_lock_lock(&capturedSinkLock); _onCapturedAudio = newValue; os_unfair_lock_unlock(&capturedSinkLock) }
    }

    /// Called (on an arbitrary thread) when either engine stops itself because
    /// the audio configuration changed — device unplugged, sample rate change,
    /// etc. The owner should stop and re-start the loop.
    public var onConfigurationChange: (() -> Void)?
    private var configObservers: [NSObjectProtocol] = []

    /// True while the loop is meant to run AND both engines are still alive.
    /// After a configuration change kills an engine, this turns false even
    /// though `start` succeeded earlier — callers use it to detect zombies.
    public var isHealthy: Bool {
        isRunning && captureEngine.isRunning && playbackEngine.isRunning
    }

    /// Smoothed input level in 0...1, updated from the capture tap. Read this
    /// for a live audio meter. Resets to 0 when the engine stops.
    private var levelLock = os_unfair_lock()
    private var _level: Float = 0
    public var currentLevel: Float {
        get { os_unfair_lock_lock(&levelLock); defer { os_unfair_lock_unlock(&levelLock) }; return _level }
    }
    private func updateLevel(_ mono: [Float]) {
        guard !mono.isEmpty else { return }
        var sum: Float = 0
        for v in mono { sum += v * v }
        let rms = (sum / Float(mono.count)).squareRoot()
        // Map RMS to a perceptual 0...1 with a little headroom, then smooth.
        let scaled = min(1, rms * 6)
        os_unfair_lock_lock(&levelLock)
        _level = _level * 0.7 + scaled * 0.3
        os_unfair_lock_unlock(&levelLock)
    }

    /// Start the loop. Captures from `inputDevice` (a real mic) and writes the
    /// denoised result to `outputDevice` (the virtual mic). Passing nil uses the
    /// system defaults. Guards against capturing from the same device we write
    /// to, which would create a feedback loop.
    public func start(inputDevice: AudioDevices.Device? = nil,
                      outputDevice: AudioDevices.Device?,
                      bypass: Bool = false) throws {
        // Ensure any previous session is fully torn down first, so a second
        // call starts from a clean graph (no duplicate nodes / stale audio).
        if isRunning { stop() }

        bypassDenoise = bypass
        // Refuse to capture and play through the same device (feedback loop).
        if let inDev = inputDevice, let outDev = outputDevice, inDev.id == outDev.id {
            throw NSError(domain: "ode.live", code: -10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Input and output devices must differ (would cause a feedback loop)."])
        }

        // Start every session from a clean slate.
        ring.reset()
        denoiser.resetStreaming()

        // If anything below throws we must tear the half-built graph down —
        // otherwise the next start() would stack a second source node.
        do {
            // --- Capture side first: route + validate the input format before
            // touching the playback graph. If the selected device just
            // disappeared, inputFormat comes back invalid (0 Hz / 0 ch) and
            // installTap would raise an uncatchable NSException — throw a
            // proper error instead of crashing the app.
            let input = captureEngine.inputNode
            if let inDev = inputDevice {
                try setInputDevice(captureEngine, deviceID: inDev.id)
            }
            let inFormat = input.inputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                throw NSError(domain: "ode.live", code: -11,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Input device has no valid format (was it disconnected?)"])
            }

            let fmt = AudioIO.monoFormat

            // --- Playback graph: source node pulls denoised audio from the ring ---
            let node = AVAudioSourceNode(format: fmt) { [ring] _, _, frameCount, audioBufferList in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let n = Int(frameCount)
                if let ptr = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                    ring.read(into: ptr, count: n)
                }
                return noErr
            }
            sourceNode = node
            playbackEngine.attach(node)
            playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: fmt)

            if let dev = outputDevice {
                try setOutputDevice(playbackEngine, deviceID: dev.id)
            }

            // --- Capture tap: mic -> denoise -> ring ---
            input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [denoiser, ring, weak self] buffer, _ in
                self?.onCapturedAudio?(buffer)
                let mono = AudioIO.resampleToMono48k(buffer)
                self?.updateLevel(mono)
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
        } catch {
            teardown()
            throw error
        }

        // Both engines stop themselves when the configuration changes (device
        // unplugged, sample-rate change). Surface that so the owner can restart
        // the loop instead of silently going dead mid-call.
        let nc = NotificationCenter.default
        for engine in [captureEngine, playbackEngine] {
            configObservers.append(nc.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.onConfigurationChange?()
            })
        }

        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        teardown()
    }

    /// Tear the graphs down to a state from which `start` can build cleanly.
    /// Safe to call on a half-built graph (start-failure path).
    private func teardown() {
        configObservers.forEach { NotificationCenter.default.removeObserver($0) }
        configObservers.removeAll()
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        _ = denoiser.flushStreaming()
        denoiser.resetStreaming()
        playbackEngine.stop()
        // Fully remove the playback source node so the next start builds a fresh
        // graph instead of stacking a second node on the mixer.
        if let node = sourceNode {
            playbackEngine.disconnectNodeOutput(node)
            playbackEngine.detach(node)
            sourceNode = nil
        }
        ring.reset()
        os_unfair_lock_lock(&levelLock); _level = 0; os_unfair_lock_unlock(&levelLock)
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
