import AVFoundation
import CoreAudio

/// Thread-safe float ring buffer between the capture/processing side and the
/// playback render callback, with jitter-buffer behavior:
///
///  • `prefill`: reads produce silence until this many samples have buffered,
///    giving processing a cushion so momentary stalls don't audibly pop. The
///    cushion re-arms after an underrun instead of stuttering sample-by-sample.
///  • `maxFill`: a cap on buffered audio — a transient stall can't otherwise
///    permanently add its backlog to the call latency; the oldest backlog is
///    dropped in one clean skip instead.
///
/// Copies use `memcpy` in at most two segments and the lock is
/// `os_unfair_lock` (priority donation), so the realtime render thread never
/// waits behind a long, low-priority critical section.
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let prefill: Int
    private let maxFill: Int
    private var readIdx = 0
    private var writeIdx = 0
    private var filled = 0
    private var primed = false
    private var lock = os_unfair_lock()

    // Session diagnostics (read via `stats`).
    private var totalWritten = 0
    private var totalRead = 0
    private var underruns = 0
    private var skips = 0
    private var lastWriteAt: CFAbsoluteTime = 0
    private var maxWriteGapMs = 0
    private var slowWrites = 0   // inter-write gaps > 150 ms

    struct Stats {
        let written: Int; let read: Int; let underruns: Int; let skips: Int
        let maxWriteGapMs: Int; let slowWrites: Int
    }
    var stats: Stats {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return Stats(written: totalWritten, read: totalRead,
                     underruns: underruns, skips: skips,
                     maxWriteGapMs: maxWriteGapMs, slowWrites: slowWrites)
    }

    init(capacity: Int, prefill: Int = 0, maxFill: Int? = nil) {
        self.capacity = capacity
        self.prefill = min(prefill, capacity)
        self.maxFill = min(maxFill ?? capacity, capacity)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress, src.count > 0 else { return }
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            var n = src.count
            var from = base
            if n > capacity {                       // keep only the newest
                from += n - capacity
                n = capacity
            }
            // Copy in ≤2 wrapped segments.
            let first = min(n, capacity - writeIdx)
            memcpy(storage + writeIdx, from, first * MemoryLayout<Float>.size)
            if n > first {
                memcpy(storage, from + first, (n - first) * MemoryLayout<Float>.size)
            }
            writeIdx = (writeIdx + n) % capacity
            filled += n
            totalWritten += n
            let now = CFAbsoluteTimeGetCurrent()
            if lastWriteAt > 0 {
                let gapMs = Int((now - lastWriteAt) * 1000)
                if gapMs > maxWriteGapMs { maxWriteGapMs = gapMs }
                if gapMs > 150 { slowWrites += 1 }
            }
            lastWriteAt = now
            if filled > capacity {                  // overwrote oldest
                readIdx = writeIdx
                filled = capacity
            }
            if filled > maxFill {
                // Skip the backlog down to the prefill cushion: one clean
                // discontinuity instead of seconds of added latency.
                let drop = filled - max(prefill, 1)
                readIdx = (readIdx + drop) % capacity
                filled -= drop
                skips += 1
            }
        }
    }

    /// Fill `out` with `count` samples; silence until primed / on underrun.
    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if !primed {
            if filled >= prefill { primed = true } else {
                memset(out, 0, count * MemoryLayout<Float>.size)
                return
            }
        }
        let n = min(count, filled)
        let first = min(n, capacity - readIdx)
        memcpy(out, storage + readIdx, first * MemoryLayout<Float>.size)
        if n > first {
            memcpy(out + first, storage, (n - first) * MemoryLayout<Float>.size)
        }
        readIdx = (readIdx + n) % capacity
        filled -= n
        totalRead += n
        if n < count {
            // Underrun: pad with silence and re-arm the cushion so we rebuffer
            // instead of stuttering.
            memset(out + n, 0, (count - n) * MemoryLayout<Float>.size)
            primed = false
            underruns += 1
        }
    }

    /// Drop all buffered audio (call between sessions to avoid stale playback).
    func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        readIdx = 0; writeIdx = 0; filled = 0; primed = false
        totalWritten = 0; totalRead = 0; underruns = 0; skips = 0
        lastWriteAt = 0; maxWriteGapMs = 0; slowWrites = 0
    }
}

/// Real-time loop: capture default mic -> denoise -> play to a target output
/// device (e.g. the virtual "ODE Microphone"). This is the streaming core that
/// the virtual "ODE Microphone" device.
public final class LiveEngine {
    /// Engines are created FRESH for every session: reusing an AVAudioEngine
    /// across start/stop cycles is unreliable with voice processing enabled —
    /// second sessions failed with invalid input formats or AU initialization
    /// errors (-10875) in the field.
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private let denoiser = Denoiser()
    /// 200 ms jitter cushion before playback starts: capture taps and the
    /// streaming denoiser both deliver in ~100 ms bursts, so a 100 ms cushion
    /// sat at the edge and underran on every scheduling hiccup (audible as
    /// periodic dropouts). Backlog capped at 500 ms so a transient stall can't
    /// permanently add latency to the call.
    private let ring = RingBuffer(capacity: 48_000 * 4,
                                  prefill: 9_600,
                                  maxFill: 24_000)

    /// Label used in diagnostics ("mic" / "speaker").
    public var label = "engine"
    /// Denoise inference runs here, not on the capture tap thread — a slow
    /// inference must never stall the audio engine's delivery pipeline.
    private let processQueue = DispatchQueue(label: "ode.live.process",
                                             qos: .userInteractive)
    private var sourceNode: AVAudioSourceNode!
    private var isRunning = false

    /// Persistent capture-format converter. Creating a converter per buffer
    /// (AudioIO.resampleToMono48k) discards the resampler's priming samples on
    /// every call — when the capture device runs at a different rate this
    /// silently loses ~10–15% of the audio, draining the ring faster than it
    /// fills (heard as periodic dropouts).
    private var captureConverter: AVAudioConverter?

    private func convertToMono48k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let dst = AudioIO.monoFormat
        if buffer.format == dst { return AudioIO.bufferToArray(buffer) }
        if captureConverter == nil || captureConverter?.inputFormat != buffer.format {
            captureConverter = AVAudioConverter(from: buffer.format, to: dst)
        }
        guard let converter = captureConverter else { return AudioIO.bufferToArray(buffer) }
        let ratio = dst.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return AudioIO.bufferToArray(out)
    }

    /// When true, audio passes through untouched (no denoising). Can be flipped
    /// live while the engine runs — the audio keeps flowing either way.
    private var bypassLock = os_unfair_lock()
    private var _bypass = false
    public var bypassDenoise: Bool {
        get { os_unfair_lock_lock(&bypassLock); defer { os_unfair_lock_unlock(&bypassLock) }; return _bypass }
        set { os_unfair_lock_lock(&bypassLock); _bypass = newValue; os_unfair_lock_unlock(&bypassLock) }
    }

    /// How much of the denoised signal to use, 0...1 (1 = full denoising,
    /// today's behavior; lower blends the original back in for naturalness).
    /// Flippable live mid-session, same pattern as bypassDenoise.
    private var strengthLock = os_unfair_lock()
    private var _strength: Float = 1
    public var denoiseStrength: Float {
        get { os_unfair_lock_lock(&strengthLock); defer { os_unfair_lock_unlock(&strengthLock) }; return _strength }
        set { os_unfair_lock_lock(&strengthLock); _strength = min(max(newValue, 0), 1); os_unfair_lock_unlock(&strengthLock) }
    }
    /// Dry/wet blender for partial strength. Touched only on processQueue.
    private let mixer = DryWetMixer()

    /// "Studio Voice" polish (EQ + compression + limiter), applied as the
    /// last stage before playback. Flippable live, same pattern as
    /// bypassDenoise.
    private var studioVoiceLock = os_unfair_lock()
    private var _studioVoice = false
    public var studioVoice: Bool {
        get { os_unfair_lock_lock(&studioVoiceLock); defer { os_unfair_lock_unlock(&studioVoiceLock) }; return _studioVoice }
        set { os_unfair_lock_lock(&studioVoiceLock); _studioVoice = newValue; os_unfair_lock_unlock(&studioVoiceLock) }
    }
    /// The polish chain itself. Touched only on processQueue.
    private let voice = StudioVoice()
    /// Tracks off→on transitions (processQueue only) so every enable starts
    /// from clean DSP state instead of stale filter memory.
    private var voicePrimed = false

    /// Whether Apple's voice processing (acoustic echo cancellation against
    /// the system output) is applied to the capture side. Read at start();
    /// settable so the owner can flip echo cancellation without swapping
    /// engines. VP capture runs on the process-wide VoiceProcessingCapture
    /// unit (one VPIO instance per process — see that type's comment for the
    /// full failure history that led here).
    public var voiceProcessing: Bool
    /// True while the CURRENT session captures via the shared VPIO unit.
    private var usingVPIO = false

    public init(voiceProcessing: Bool = false) {
        self.voiceProcessing = voiceProcessing
    }

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

    /// Optional sink for the FINAL processed samples (post-denoise,
    /// post-Studio-Voice — exactly what the ring plays to the other side),
    /// 48 kHz mono. Used for call recording. Invoked on the serial
    /// processing queue; keep the closure cheap or hop queues inside it.
    private var processedSinkLock = os_unfair_lock()
    private var _onProcessedAudio: (([Float]) -> Void)?
    public var onProcessedAudio: (([Float]) -> Void)? {
        get { os_unfair_lock_lock(&processedSinkLock); defer { os_unfair_lock_unlock(&processedSinkLock) }; return _onProcessedAudio }
        set { os_unfair_lock_lock(&processedSinkLock); _onProcessedAudio = newValue; os_unfair_lock_unlock(&processedSinkLock) }
    }

    /// Called (on an arbitrary thread) when either engine stops itself because
    /// the audio configuration changed — device unplugged, sample rate change,
    /// etc. The owner should stop and re-start the loop.
    public var onConfigurationChange: (() -> Void)?
    private var configObservers: [NSObjectProtocol] = []
    /// Engine setup (voice processing especially) fires configuration-change
    /// notifications of its own; reacting to those restarts the engine in a
    /// loop. Changes within this window of a start are ignored.
    private var startedAtTime: CFAbsoluteTime = 0

    /// Set at the top of start(); health checks give a grace period while a
    /// start executes on the engine queue — otherwise the device-change storm
    /// that voice-processing setup fires makes the owner's zombie detection
    /// kill the engine WHILE it is starting.
    private var startInitiatedAt: CFAbsoluteTime = 0

    /// True while the loop is meant to run AND both engines are still alive.
    /// After a configuration change kills an engine, this turns false even
    /// though `start` succeeded earlier — callers use it to detect zombies.
    /// While a start is still in flight it reports healthy (grace period).
    public var isHealthy: Bool {
        if isRunning {
            let captureAlive = usingVPIO
                ? VoiceProcessingCapture.shared.isAlive
                : captureEngine?.isRunning == true
            return captureAlive && playbackEngine?.isRunning == true
        }
        return CFAbsoluteTimeGetCurrent() - startInitiatedAt < 3.0
    }

    /// Smoothed input level in 0...1, updated from the capture tap. Read this
    /// for a live audio meter. Resets to 0 when the engine stops.
    private var levelLock = os_unfair_lock()
    private var _level: Float = 0
    private var _sessionPeak: Float = 0
    public var currentLevel: Float {
        get { os_unfair_lock_lock(&levelLock); defer { os_unfair_lock_unlock(&levelLock) }; return _level }
    }
    /// Loudest input sample seen this session. Exactly 0 after seconds of a
    /// running session means the capture is dead (permission, device) — even
    /// a quiet room registers a noise floor.
    public var sessionPeak: Float {
        get { os_unfair_lock_lock(&levelLock); defer { os_unfair_lock_unlock(&levelLock) }; return _sessionPeak }
    }
    private func updateLevel(_ mono: [Float]) {
        guard !mono.isEmpty else { return }
        var sum: Float = 0
        var peak: Float = 0
        for v in mono {
            sum += v * v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let rms = (sum / Float(mono.count)).squareRoot()
        // Map RMS to a perceptual 0...1 with a little headroom, then smooth.
        let scaled = min(1, rms * 6)
        os_unfair_lock_lock(&levelLock)
        _level = _level * 0.7 + scaled * 0.3
        if peak > _sessionPeak { _sessionPeak = peak }
        os_unfair_lock_unlock(&levelLock)
    }

    /// Start the loop. Captures from `inputDevice` (a real mic) and writes the
    /// denoised result to `outputDevice` (the virtual mic). Passing nil uses the
    /// system defaults. Guards against capturing from the same device we write
    /// to, which would create a feedback loop.
    ///
    public func start(inputDevice: AudioDevices.Device? = nil,
                      outputDevice: AudioDevices.Device?,
                      bypass: Bool = false) throws {
        // Ensure any previous session is fully torn down first, so a second
        // call starts from a clean graph (no duplicate nodes / stale audio).
        if isRunning { stop() }
        startInitiatedAt = CFAbsoluteTimeGetCurrent()

        bypassDenoise = bypass
        // Refuse to capture and play through the same device (feedback loop).
        if let inDev = inputDevice, let outDev = outputDevice, inDev.id == outDev.id {
            startInitiatedAt = 0  // failed starts get no health grace
            throw NSError(domain: "ode.live", code: -10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Input and output devices must differ (would cause a feedback loop)."])
        }

        // Start every session from a clean slate.
        ring.reset()
        denoiser.resetStreaming()
        mixer.reset()
        voice.reset()
        os_unfair_lock_lock(&levelLock); _sessionPeak = 0; os_unfair_lock_unlock(&levelLock)

        // Playback engine is fresh every session; capture is either a fresh
        // engine (plain path) or the process-wide VPIO unit (echo cancel).
        usingVPIO = voiceProcessing
        let playback = AVAudioEngine()
        playbackEngine = playback
        let capture: AVAudioEngine? = usingVPIO ? nil : AVAudioEngine()
        captureEngine = capture

        // If anything below throws we must tear the half-built graph down —
        // otherwise the next start() would stack a second source node.
        do {
            var inFormat: AVAudioFormat?
            if let capture {
                // --- Plain capture engine, pinned to the selected device ---
                let input = capture.inputNode
                if let inDev = inputDevice {
                    try setInputDevice(capture, deviceID: inDev.id)
                }
                // Validate the format: if the device just disappeared it comes
                // back invalid (0 Hz), and installTap would raise an uncatchable
                // NSException — throw a proper error instead of crashing.
                let f = input.inputFormat(forBus: 0)
                guard f.sampleRate > 0, f.channelCount > 0 else {
                    throw NSError(domain: "ode.live", code: -11,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Input device has no valid format (was it disconnected?)"])
                }
                inFormat = f
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
            playback.attach(node)
            playback.connect(node, to: playback.mainMixerNode, format: fmt)

            if let dev = outputDevice {
                try setOutputDevice(playback, deviceID: dev.id)
            }

            captureConverter = nil  // fresh converter state per session
            if let capture, let inFormat {
                // --- Capture tap: mic -> (process queue: denoise) -> ring ---
                capture.inputNode.installTap(onBus: 0, bufferSize: 480,
                                             format: inFormat) { [weak self] buffer, _ in
                    self?.processCaptured(buffer)
                }
                capture.prepare()
                playback.prepare()
                try playback.start()
                try capture.start()
            } else {
                // --- VPIO capture: shared unit, initialized once at launch.
                // It always follows the system default input (VPIO manages
                // its own device pair; pinning breaks it).
                playback.prepare()
                try playback.start()
                try VoiceProcessingCapture.shared.start { [weak self] buffer in
                    self?.processCaptured(buffer)
                }
                VoiceProcessingCapture.shared.onFailure = { [weak self] in
                    guard let self else { return }
                    guard CFAbsoluteTimeGetCurrent() - self.startedAtTime > 1.0 else { return }
                    self.onConfigurationChange?()
                }
            }
        } catch {
            startInitiatedAt = 0  // failed starts get no health grace
            teardown()
            throw error
        }

        // Engines stop themselves when the configuration changes (device
        // unplugged, sample-rate change). Surface that so the owner can restart
        // the loop instead of silently going dead mid-call.
        let nc = NotificationCenter.default
        for engine in [capture, playback].compactMap({ $0 }) {
            configObservers.append(nc.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                // Ignore the change events our own setup produces.
                guard CFAbsoluteTimeGetCurrent() - self.startedAtTime > 1.0 else { return }
                self.onConfigurationChange?()
            })
        }

        startedAtTime = CFAbsoluteTimeGetCurrent()
        isRunning = true
    }

    /// Shared capture-processing body — identical for the plain engine tap
    /// and the VPIO sink: transcription feed, meters, then serial-queue
    /// denoise/blend into the ring.
    private func processCaptured(_ buffer: AVAudioPCMBuffer) {
        onCapturedAudio?(buffer)
        let mono = convertToMono48k(buffer)
        updateLevel(mono)
        // Hand off to the serial processing queue: keeps inference off the
        // audio thread (order is preserved; the ring's prefill cushion
        // absorbs scheduling jitter).
        processQueue.async { [weak self] in
            guard let self else { return }
            if self.bypassDenoise {
                // Pass audio through untouched so the call still hears you,
                // just without noise removal. Studio Voice still applies —
                // the two toggles compose independently.
                self.emit(mono)
            } else {
                let s = self.denoiseStrength
                // At full strength the FIFO must stay empty, or dry samples
                // left from a lower setting would misalign the next blend
                // when strength drops again.
                if s < 0.999 { self.mixer.feed(dry: mono) } else { self.mixer.reset() }
                let clean = self.denoiser.processStreaming(mono)
                if !clean.isEmpty {
                    self.emit(s < 0.999 ? self.mixer.mix(wet: clean, strength: s)
                                        : clean)
                }
            }
        }
    }

    /// Final hop for processed samples (processQueue only): Studio Voice
    /// polish when enabled, then the ring for playback plus the optional
    /// processed-audio sink (call recording).
    private func emit(_ samples: [Float]) {
        var out = samples
        if studioVoice {
            if !voicePrimed { voice.reset(); voicePrimed = true }
            out = voice.process(out)
        } else {
            voicePrimed = false
        }
        ring.write(out)
        onProcessedAudio?(out)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        logSessionStats()
        teardown()
    }

    /// Session diagnostics: NSLog + append to a stats file, because unified
    /// log access has proven unreliable when debugging in the field. A zero
    /// input peak on the mic path means the OS delivered silence (microphone
    /// permission denied).
    private func logSessionStats() {
        let s = ring.stats
        os_unfair_lock_lock(&levelLock)
        let peak = _sessionPeak
        os_unfair_lock_unlock(&levelLock)
        let line = String(format: "[%@] wrote=%d played=%d underruns=%d skips=%d inPeak=%.4f maxWriteGap=%dms slowWrites=%d",
                          label, s.written, s.read, s.underruns, s.skips, peak,
                          s.maxWriteGapMs, s.slowWrites)
        Self.diagnostic(line)
    }

    /// Append a timestamped line to the field-diagnostics log (NSLog mirror).
    /// Unified-log access has proven unreliable when debugging in the field.
    public static func diagnostic(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        NSLog("ODE live: %@", line)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
            .appendingPathComponent("ODE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine-stats.log")
        let data = (line + "\n").data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Tear the session down completely. The engines are DISCARDED, not
    /// reused — reuse across sessions proved unreliable with voice processing.
    /// Safe to call on a half-built graph (start-failure path).
    private func teardown() {
        configObservers.forEach { NotificationCenter.default.removeObserver($0) }
        configObservers.removeAll()
        if usingVPIO {
            // Mic released; the shared unit stays initialized for next time.
            VoiceProcessingCapture.shared.onFailure = nil
            VoiceProcessingCapture.shared.stop()
            usingVPIO = false
        }
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        // Drain in-flight inference before touching the denoiser's state.
        processQueue.sync {}
        _ = denoiser.flushStreaming()
        denoiser.resetStreaming()
        mixer.reset()
        voice.reset()
        playbackEngine?.stop()
        sourceNode = nil
        captureEngine = nil
        playbackEngine = nil
        ring.reset()
        os_unfair_lock_lock(&levelLock); _level = 0; os_unfair_lock_unlock(&levelLock)
    }

    /// Route an AVAudioEngine's output to a specific CoreAudio device.
    private func setOutputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else {
            // Failing silently here would leave the engine on the DEFAULT
            // output — leaking mic audio to the user's speakers instead of
            // feeding the virtual device.
            throw NSError(domain: "ode.live", code: -12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Output node has no audio unit (cannot pin output device)"])
        }
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
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "ode.live", code: -13,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Input node has no audio unit (cannot pin input device)"])
        }
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
