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
/// Capture liveness and drop bookkeeping, split out from the audio unit so
/// the rules can be exercised without a device: pure state plus an injected
/// clock, no CoreAudio. `HALCapture` owns one and does nothing else with it.
struct CaptureLiveness {
    /// A started unit that stops delivering for this long is dead. Two
    /// seconds is far longer than any legitimate IO gap (a 512-frame buffer
    /// at 48 kHz is ~10 ms) and short enough to recover inside a sentence.
    static let deliveryDeadline: CFAbsoluteTime = 2.0

    private(set) var lastDeliveryAt: CFAbsoluteTime = 0
    private(set) var renderFailures = 0
    private(set) var allocFailures = 0
    private(set) var lastRenderStatus: OSStatus = noErr
    private var reported = false

    /// Record that a buffer arrived. Called from the IO thread.
    mutating func stamp(at now: CFAbsoluteTime) { lastDeliveryAt = now }

    mutating func noteRenderFailure(_ status: OSStatus) {
        renderFailures += 1
        lastRenderStatus = status
    }

    mutating func noteAllocFailure() { allocFailures += 1 }

    /// Seconds since the last delivered buffer.
    func silence(at now: CFAbsoluteTime) -> CFAbsoluteTime { now - lastDeliveryAt }

    func isStalled(at now: CFAbsoluteTime,
                   deadline: CFAbsoluteTime = CaptureLiveness.deliveryDeadline) -> Bool {
        silence(at: now) > deadline
    }

    /// Drops worth logging, yielded exactly once per session: the IO thread
    /// only counts (the diagnostics log is a file write), so whoever polls
    /// this does the reporting — and must not repeat it every tick.
    mutating func takeUnreportedDrops() -> (render: Int, status: OSStatus, alloc: Int)? {
        guard renderFailures > 0 || allocFailures > 0, !reported else { return nil }
        reported = true
        return (renderFailures, lastRenderStatus, allocFailures)
    }
}

final class HALCapture {
    private var unit: AudioUnit?

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

    // MARK: - Liveness

    /// Queue for the death watch: the alive-listener and the delivery
    /// watchdog. Never the IO thread.
    private static let watchQueue = DispatchQueue(label: "ode.capture.watch", qos: .utility)

    /// Guards `_isRunning`, `failed` and `watchdog` — written from the watch
    /// queue (death) and the engine queue (start/dispose), read from main.
    private var stateLock = os_unfair_lock()
    private var _isRunning = false
    private var failed = false
    private var watchdog: DispatchSourceTimer?

    /// True while the unit is started AND still delivering audio. Goes false
    /// when the device dies or delivery stalls: `LiveEngine.isHealthy` reads
    /// this, and until it could go false a mid-call mic death stayed
    /// invisible for the rest of the call.
    var isRunning: Bool {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _isRunning
    }
    private func setRunning(_ value: Bool) {
        os_unfair_lock_lock(&stateLock); _isRunning = value; os_unfair_lock_unlock(&stateLock)
    }

    /// Called (on the watch queue) the first time capture dies. There is no
    /// AVAudioEngine behind a raw AUHAL unit and therefore no configuration
    /// -change notification: this is the only signal that capture went away.
    private var onFailureLock = os_unfair_lock()
    private var _onFailure: (() -> Void)?
    var onFailure: (() -> Void)? {
        get { os_unfair_lock_lock(&onFailureLock); defer { os_unfair_lock_unlock(&onFailureLock) }; return _onFailure }
        set { os_unfair_lock_lock(&onFailureLock); _onFailure = newValue; os_unfair_lock_unlock(&onFailureLock) }
    }

    /// The pinned device, watched for disappearance.
    private var deviceID: AudioDeviceID = 0
    private var aliveAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var aliveBlock: AudioObjectPropertyListenerBlock?

    /// Delivery/drop bookkeeping, under `onAudioLock` — the lock the IO
    /// thread already takes once per callback.
    private var liveness = CaptureLiveness()

    /// Snapshot for the session stats line. A device that starts erroring
    /// otherwise produces pure silence with no trace anywhere — the hardest
    /// failure in this app to diagnose.
    var stats: CaptureLiveness {
        os_unfair_lock_lock(&onAudioLock); defer { os_unfair_lock_unlock(&onAudioLock) }
        return liveness
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
            self.deviceID = resolved

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
        // The delivery deadline runs from the start, not from the first
        // buffer — a unit that starts cleanly and never delivers anything is
        // exactly one of the failures this file was written for.
        os_unfair_lock_lock(&onAudioLock)
        liveness.stamp(at: CFAbsoluteTimeGetCurrent())
        os_unfair_lock_unlock(&onAudioLock)
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw Self.err("AudioOutputUnitStart", status) }
        setRunning(true)
        installAliveListener()
        startWatchdog()
    }

    func dispose() {
        cancelWatchdog()
        removeAliveListener()
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        setRunning(false)
        onAudio = nil
        onFailure = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    // MARK: - Death watch

    /// The pinned device vanishing is the fast, unambiguous path to knowing
    /// capture is dead — quicker than waiting out the delivery deadline.
    private func installAliveListener() {
        guard deviceID != 0, aliveBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = self.aliveAddr
            let status = AudioObjectGetPropertyData(self.deviceID, &addr, 0, nil, &size, &alive)
            if status != noErr || alive == 0 {
                self.fail("capture device disappeared")
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            deviceID, &aliveAddr, Self.watchQueue, block) == noErr {
            aliveBlock = block
        }
    }

    private func removeAliveListener() {
        guard let block = aliveBlock, deviceID != 0 else { return }
        AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddr, Self.watchQueue, block)
        aliveBlock = nil
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: Self.watchQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        os_unfair_lock_lock(&stateLock); watchdog = timer; os_unfair_lock_unlock(&stateLock)
        timer.resume()
    }

    private func cancelWatchdog() {
        os_unfair_lock_lock(&stateLock)
        let timer = watchdog
        watchdog = nil
        os_unfair_lock_unlock(&stateLock)
        timer?.cancel()
    }

    /// One tick: surface the first render failure, then enforce the delivery
    /// deadline. A unit that started clean and then went quiet is the failure
    /// mode that used to survive a whole call unnoticed.
    private func checkLiveness() {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&onAudioLock)
        let stalled = liveness.isStalled(at: now)
        let silentFor = liveness.silence(at: now)
        let drops = liveness.takeUnreportedDrops()
        os_unfair_lock_unlock(&onAudioLock)

        if let d = drops {
            LiveEngine.diagnostic(
                "[capture] dropping buffers (render \(d.render), OSStatus \(d.status), alloc \(d.alloc))")
        }
        if stalled {
            fail(String(format: "no audio from the capture device for %.1fs", silentFor))
        }
    }

    /// Report death exactly once: stop claiming to be running, then hand off
    /// to the owner for a restart. Clearing `isRunning` is what lets
    /// `LiveEngine.isHealthy` — and through it the controller's zombie
    /// watchdog — see this at all.
    private func fail(_ reason: String) {
        os_unfair_lock_lock(&stateLock)
        if failed { os_unfair_lock_unlock(&stateLock); return }
        failed = true
        _isRunning = false
        os_unfair_lock_unlock(&stateLock)
        cancelWatchdog()
        LiveEngine.diagnostic("[capture] \(reason) — reporting for restart")
        onFailure?()
    }

    // MARK: - Render-thread delivery

    fileprivate func deliverInput(_ frames: UInt32, _ timestamp: UnsafePointer<AudioTimeStamp>) {
        guard let unit, let fmt = format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
            noteDrop(alloc: true, status: noErr)
            return
        }
        buffer.frameLength = frames
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in 0..<abl.count { abl[i].mDataByteSize = frames * 4 }
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, timestamp, 1, frames,
                                     buffer.mutableAudioBufferList)
        guard status == noErr else {
            noteDrop(alloc: false, status: status)
            return
        }
        // Stamp liveness inside the lock the sink read already needs, so the
        // watchdog gets its deadline for free rather than at the cost of
        // another acquisition on the IO thread.
        os_unfair_lock_lock(&onAudioLock)
        liveness.stamp(at: CFAbsoluteTimeGetCurrent())
        let sink = _onAudio
        os_unfair_lock_unlock(&onAudioLock)
        sink?(buffer)
    }

    /// Count a dropped buffer. Counting only: the IO thread must never touch
    /// the diagnostics log (it is a file write) — the watchdog tick reports.
    private func noteDrop(alloc: Bool, status: OSStatus) {
        os_unfair_lock_lock(&onAudioLock)
        if alloc { liveness.noteAllocFailure() } else { liveness.noteRenderFailure(status) }
        os_unfair_lock_unlock(&onAudioLock)
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
