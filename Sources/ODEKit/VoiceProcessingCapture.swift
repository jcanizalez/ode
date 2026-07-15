import Foundation
import AVFoundation
import AudioToolbox

/// Process-wide voice-processing (echo-cancelling) microphone capture,
/// built on the raw VoiceProcessingIO AudioUnit.
///
/// Why not AVAudioEngine: engine.stop() uninitializes the underlying VPIO
/// unit and tears down its private aggregate device; the next start() re-runs
/// AudioUnitInitialize against stale state and fails (-10875) — the original
/// "mic dead in the second meeting" bug. A dormant second VPIO instance held
/// as a warm-up makes every real session capture silence instead. The working
/// pattern — the one telephony apps use — is exactly ONE VPIO instance per
/// process, initialized ONCE (that's when the device-stack storm happens, so
/// do it at launch, off-call), then AudioOutputUnitStart/Stop per session.
/// Stop releases the microphone (no orange indicator between calls) while
/// the unit stays initialized and ready.
public final class VoiceProcessingCapture {
    public static let shared = VoiceProcessingCapture()
    private init() {}

    private var unit: AudioUnit?
    private var prepared = false
    private var running = false
    private let lock = NSLock()

    /// Sink for captured, echo-cancelled audio (arbitrary audio thread).
    private var onAudioLock = os_unfair_lock()
    private var _onAudio: ((AVAudioPCMBuffer) -> Void)?
    private var onAudio: ((AVAudioPCMBuffer) -> Void)? {
        get { os_unfair_lock_lock(&onAudioLock); defer { os_unfair_lock_unlock(&onAudioLock) }; return _onAudio }
        set { os_unfair_lock_lock(&onAudioLock); _onAudio = newValue; os_unfair_lock_unlock(&onAudioLock) }
    }

    /// Wall-clock of the last delivered input buffer (atomic via lock).
    private var lastBufferLock = os_unfair_lock()
    private var _lastBufferAt: CFAbsoluteTime = 0
    private var lastBufferAt: CFAbsoluteTime {
        get { os_unfair_lock_lock(&lastBufferLock); defer { os_unfair_lock_unlock(&lastBufferLock) }; return _lastBufferAt }
        set { os_unfair_lock_lock(&lastBufferLock); _lastBufferAt = newValue; os_unfair_lock_unlock(&lastBufferLock) }
    }

    /// Called (arbitrary thread) when the unit stops delivering audio and the
    /// recovery ladder failed — the owner should restart its session.
    public var onFailure: (() -> Void)?

    /// The unit's client-side format (mono float, unit-preferred rate).
    private var clientFormat: AVAudioFormat?

    /// Liveness: running and audio flowed within the last 2 s. During the
    /// first 3 s after start we're optimistic (device spin-up).
    private var startedAt: CFAbsoluteTime = 0
    public var isAlive: Bool {
        lock.lock(); let isRunning = running; lock.unlock()
        guard isRunning else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        if now - startedAt < 3 { return true }
        return now - lastBufferAt < 2
    }

    // MARK: - Lifecycle

    /// Stand the voice-processing stack up. Heavy — the first initialization
    /// reconfigures the system's default-device stack (the "storm"), so call
    /// this at app launch or EC toggle-on, never at session start. Idempotent.
    public func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        guard !prepared else { return }
        try buildAndInitialize()
        prepared = true
        LiveEngine.diagnostic("[vpio] prepared (voice-processing stack up)")
    }

    /// Begin a capture session. `prepare()` is called if needed.
    public func start(onAudio sink: @escaping (AVAudioPCMBuffer) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if !prepared { try buildAndInitialize(); prepared = true }
        guard let unit else { throw err("no audio unit", -1) }
        onAudio = sink
        lastBufferAt = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            onAudio = nil
            throw err("AudioOutputUnitStart", status)
        }
        running = true
        LiveEngine.diagnostic("[vpio] session started")
    }

    /// End the capture session. The microphone is released (indicator off);
    /// the unit stays initialized for the next session.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running, let unit else { onAudio = nil; return }
        AudioOutputUnitStop(unit)
        running = false
        onAudio = nil
        LiveEngine.diagnostic("[vpio] session stopped (mic released)")
    }

    /// Recovery ladder for a wedged unit: restart → reinitialize → recreate.
    /// Returns true if a rung got audio structurally flowing again (the
    /// caller's health checks confirm actual delivery).
    @discardableResult
    public func recover() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let unit else { return false }
        let sink = onAudio

        // Rung 1: stop/start.
        AudioOutputUnitStop(unit)
        if AudioOutputUnitStart(unit) == noErr {
            LiveEngine.diagnostic("[vpio] recovered via restart")
            startedAt = CFAbsoluteTimeGetCurrent()
            return true
        }
        // Rung 2: uninitialize/initialize.
        AudioUnitUninitialize(unit)
        if AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr {
            LiveEngine.diagnostic("[vpio] recovered via reinitialize")
            startedAt = CFAbsoluteTimeGetCurrent()
            return true
        }
        // Rung 3: full teardown and rebuild (re-fires the storm — we're
        // already broken, so it can't make things worse).
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        prepared = false
        do {
            try buildAndInitialize()
            prepared = true
            if let fresh = self.unit, AudioOutputUnitStart(fresh) == noErr {
                onAudio = sink
                LiveEngine.diagnostic("[vpio] recovered via full rebuild")
                startedAt = CFAbsoluteTimeGetCurrent()
                return true
            }
        } catch {
            LiveEngine.diagnostic("[vpio] rebuild failed: \(error.localizedDescription)")
        }
        running = false
        return false
    }

    // MARK: - Unit construction

    private func buildAndInitialize() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw err("VoiceProcessingIO component not found", -1)
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &newUnit)
        guard status == noErr, let u = newUnit else { throw err("InstanceNew", status) }

        // Bus 1 = microphone input (enable); bus 0 = output side. VPIO wants
        // its output side alive to run AEC against; we feed it silence.
        var one: UInt32 = 1
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &one,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw err("EnableIO input", status) }
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &one,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw err("EnableIO output", status) }

        // Client format for what WE read on bus 1: Float32 mono 48 kHz —
        // the engine's convertToMono48k normalizes anything, but asking for
        // the pipeline's native rate avoids a resample when granted.
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 48_000, channels: 1,
                                      interleaved: false) else {
            throw err("client format", -1)
        }
        var asbd = fmt.streamDescription.pointee
        status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw err("StreamFormat bus1", status) }
        // The SAME client format must also be set on the speaker side we
        // feed (input scope, bus 0) — VPIO refuses to initialize (-10875)
        // when the two client formats don't agree.
        status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw err("StreamFormat bus0", status) }
        clientFormat = fmt

        // AGC off — parity with the AVAudioEngine configuration.
        var zero: UInt32 = 0
        AudioUnitSetProperty(u, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                             kAudioUnitScope_Global, 1, &zero,
                             UInt32(MemoryLayout<UInt32>.size))

        // Input callback: pull echo-cancelled mic audio.
        var inputCb = AURenderCallbackStruct(
            inputProc: vpInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 1, &inputCb,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw err("SetInputCallback", status) }

        // Output render callback: silence (VPIO's speaker side is unused —
        // ODE's playback runs on its own engine).
        var renderCb = AURenderCallbackStruct(
            inputProc: vpSilenceCallback, inputProcRefCon: nil)
        status = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &renderCb,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw err("SetRenderCallback", status) }

        // The storm: first VPIO initialization reconfigures the system's
        // default-device stack. This is why prepare() runs off-call.
        status = AudioUnitInitialize(u)
        guard status == noErr else {
            AudioComponentInstanceDispose(u)
            throw err("AudioUnitInitialize", status)
        }
        unit = u
    }

    // MARK: - Render-thread delivery (called from the C callbacks)

    fileprivate func deliverInput(_ frames: UInt32, _ timestamp: UnsafePointer<AudioTimeStamp>) {
        guard let unit, let fmt = clientFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: frames * 4,
                                  mData: buffer.floatChannelData![0]))
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, timestamp, 1, frames, &abl)
        guard status == noErr else { return }
        lastBufferAt = CFAbsoluteTimeGetCurrent()
        onAudio?(buffer)
    }

    private func err(_ what: String, _ code: OSStatus) -> NSError {
        NSError(domain: "ode.vpio", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "VPIO \(what) failed (\(code))"])
    }
}

/// Mic-side callback: VPIO has echo-cancelled input ready — render and forward.
private func vpInputCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<VoiceProcessingCapture>.fromOpaque(refCon).takeUnretainedValue()
    capture.deliverInput(frames, timestamp)
    return noErr
}

/// Speaker-side callback: we don't play through VPIO — hand back silence.
private func vpSilenceCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    if let abl = data {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for buf in buffers {
            if let mData = buf.mData { memset(mData, 0, Int(buf.mDataByteSize)) }
        }
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
