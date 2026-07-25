import Foundation
import AVFoundation
import AudioToolbox

/// Plain (non-echo-cancelled) microphone/tap capture on a raw AUHAL unit.
///
/// Why not AVAudioEngine: its input node's client format silently tracks the
/// SYSTEM DEFAULT input device, not the device the engine was pinned to, and
/// it renegotiates when the default changes mid-start. Against that belief
/// system every tap-format choice loses somewhere: the engine's reported
/// format can describe the wrong device ("format mismatch" at install), a
/// nil tap inherits the same stale format (start dies with -10868), and a
/// HAL-true format the engine disagrees with starts cleanly but delivers
/// nothing. Four distinct field failures, one root. A raw AUHAL unit has no
/// beliefs: WE pin the device and WE set the client format — the device's
/// true rate, from the HAL — and it either works or reports an honest error.
///
/// One instance per capture session (built in LiveEngine.start, disposed in
/// teardown). Unlike VPIO there is no init "storm": plain AUHAL touches only
/// the pinned device.
final class HALCapture {
    private var unit: AudioUnit?
    private(set) var isRunning = false

    /// Client-side format: the device's true rate/channels, Float32
    /// deinterleaved. AUHAL converts layout but never resamples input, so
    /// the rate MUST be the device's own.
    private(set) var format: AVAudioFormat?

    /// Sink for captured audio (render thread).
    private var onAudioLock = os_unfair_lock()
    private var _onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onAudio: ((AVAudioPCMBuffer) -> Void)? {
        get { os_unfair_lock_lock(&onAudioLock); defer { os_unfair_lock_unlock(&onAudioLock) }; return _onAudio }
        set { os_unfair_lock_lock(&onAudioLock); _onAudio = newValue; os_unfair_lock_unlock(&onAudioLock) }
    }

    /// Build and initialize against a device (nil = system default input).
    init(deviceID: AudioDeviceID?) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw Self.err("AUHAL component not found", -1)
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &newUnit)
        guard status == noErr, let u = newUnit else { throw Self.err("InstanceNew", status) }
        // From here on, failures must dispose the half-built unit.
        do {
            // Enable input (bus 1), disable output (bus 0) — capture only.
            var one: UInt32 = 1, zero: UInt32 = 0
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                          kAudioUnitScope_Input, 1, &one,
                                          UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw Self.err("EnableIO input", status) }
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                          kAudioUnitScope_Output, 0, &zero,
                                          UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw Self.err("EnableIO output", status) }

            // Pin the device (before formats — the device defines the rate).
            var resolved: AudioDeviceID
            if let deviceID {
                resolved = deviceID
            } else {
                resolved = try Self.defaultInputDevice()
            }
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &resolved,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw Self.err("CurrentDevice", status) }

            // Client format = the device's true input format, straight from
            // the HAL. A vanished device has no valid format — honest error.
            guard let fmt = Self.hardwareInputFormat(deviceID: resolved) else {
                throw Self.err("device has no valid input format (disconnected?)", -11)
            }
            var asbd = fmt.streamDescription.pointee
            status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output, 1, &asbd,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else { throw Self.err("StreamFormat bus1", status) }
            format = fmt

            var inputCb = AURenderCallbackStruct(
                inputProc: halInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
                                          kAudioUnitScope_Global, 1, &inputCb,
                                          UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw Self.err("SetInputCallback", status) }

            status = AudioUnitInitialize(u)
            guard status == noErr else { throw Self.err("AudioUnitInitialize", status) }
        } catch {
            AudioComponentInstanceDispose(u)
            throw error
        }
        unit = u
    }

    deinit { dispose() }

    func start() throws {
        guard let unit else { throw Self.err("no unit", -1) }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw Self.err("AudioOutputUnitStart", status) }
        isRunning = true
    }

    func dispose() {
        guard let unit else { return }
        if isRunning { AudioOutputUnitStop(unit) }
        isRunning = false
        onAudio = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    // MARK: - Render-thread delivery

    fileprivate func deliverInput(_ frames: UInt32, _ timestamp: UnsafePointer<AudioTimeStamp>) {
        guard let unit, let fmt = format,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in 0..<abl.count { abl[i].mDataByteSize = frames * 4 }
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, timestamp, 1, frames,
                                     buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        onAudio?(buffer)
    }

    // MARK: - HAL queries

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &dev)
        guard status == noErr, dev != 0 else { throw err("no default input device", status) }
        return dev
    }

    /// The device's true input format: nominal sample rate + input-scope
    /// channel count, Float32 deinterleaved. Nil if the device is gone or
    /// has no input streams.
    static func hardwareInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate) == noErr,
              rate > 0 else { return nil }

        var cfgAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var cfgSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &cfgAddr, 0, nil, &cfgSize) == noErr,
              cfgSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(cfgSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &cfgAddr, 0, nil, &cfgSize, raw) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate,
                             channels: AVAudioChannelCount(channels))
    }

    private static func err(_ what: String, _ code: OSStatus) -> NSError {
        NSError(domain: "ode.halcapture", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "capture \(what) failed (\(code))"])
    }
}

/// AUHAL input callback: audio is ready on bus 1 — render and forward.
private func halInputCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue()
    capture.deliverInput(frames, timestamp)
    return noErr
}
