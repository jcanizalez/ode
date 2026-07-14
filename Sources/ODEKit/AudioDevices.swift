import AVFoundation
import CoreAudio

/// CoreAudio device discovery helpers.
public enum AudioDevices {
    public struct Device {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let hasInput: Bool
        public let hasOutput: Bool
        public let isHidden: Bool
    }

    public static func all() -> [Device] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { device(for: $0) }
    }

    private static func device(for id: AudioDeviceID) -> Device {
        Device(id: id,
               uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "",
               name: stringProp(id, kAudioObjectPropertyName) ?? "Unknown",
               hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
               hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
               isHidden: isDeviceHidden(id))
    }

    private static func isDeviceHidden(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    public static func find(name: String) -> Device? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? all().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    /// Resolve any device (including hidden ones) by its CoreAudio UID. Used to
    /// reach the hidden feed/tap devices that back the visible ODE devices.
    public static func findByUID(_ uid: String) -> Device? {
        var translated = AudioDeviceID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr,
                                       &outSize, &translated)
        }
        guard status == noErr, translated != AudioDeviceID(kAudioObjectUnknown) else {
            // Fall back to scanning (hidden devices are still enumerated).
            return all().first { $0.uid == uid }
        }
        return device(for: translated)
    }

    public static func defaultOutput() -> Device? {
        deviceFor(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func defaultInput() -> Device? {
        deviceFor(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - ODE device visibility

    /// Custom driver property ('odev') on the visible ODE devices. Setting the
    /// CFString "1" shows the device; "0" hides it. The driver auto-hides ~15 s
    /// after the last "1", so callers must re-send it periodically (heartbeat)
    /// while the app runs. Devices stay resolvable by UID while hidden.
    private static let visibilitySelector: AudioObjectPropertySelector = 0x6F646576 // 'odev'

    /// Show or hide a visible ODE device (resolved by UID, works while hidden).
    /// Returns true when the driver accepted the change.
    @discardableResult
    public static func setVisible(_ visible: Bool, uid: String) -> Bool {
        guard let device = findByUID(uid) else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: visibilitySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = (visible ? "1" : "0") as CFString
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(device.id, &addr, 0, nil,
                                       UInt32(MemoryLayout<CFString>.size), ptr)
        }
        return status == noErr
    }

    // MARK: - Device usage observation

    /// Whether the device's **input** is currently in use by any process.
    /// Backed by `kAudioDevicePropertyDeviceIsRunningSomewhere`, scoped to the
    /// input side so that our own writes to the device's output (when routing
    /// denoised audio) do not count as usage — only an app *reading* the
    /// virtual microphone does. This is how we detect that e.g. Zoom opened it.
    public static func isInputInUse(_ id: AudioDeviceID) -> Bool {
        isInUse(id, scope: kAudioObjectPropertyScopeInput)
    }

    /// Whether the device's **output** is currently in use by any process — i.e.
    /// an app is *playing audio into* it. Used to detect that a call app is
    /// sending its incoming audio to the "ODE Speaker" device.
    public static func isOutputInUse(_ id: AudioDeviceID) -> Bool {
        isInUse(id, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func isInUse(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// Observes input-usage changes for a device. The handler is invoked on a
    /// background CoreAudio queue whenever usage changes; returns a token that
    /// must be retained and passed to `removeUsageObserver` to stop.
    public final class UsageObserver {
        let id: AudioDeviceID
        let block: AudioObjectPropertyListenerBlock
        var addr: AudioObjectPropertyAddress

        init(id: AudioDeviceID, block: @escaping AudioObjectPropertyListenerBlock,
             addr: AudioObjectPropertyAddress) {
            self.id = id
            self.block = block
            self.addr = addr
        }
    }

    public static func addUsageObserver(_ id: AudioDeviceID,
                                        readScope: AudioObjectPropertyScope = kAudioObjectPropertyScopeInput,
                                        onChange: @escaping (Bool) -> Void) -> UsageObserver? {
        // Register on the GLOBAL scope: CoreAudio posts IsRunningSomewhere change
        // notifications there. We *read* a chosen scope in the handler — input
        // for the virtual mic (an app reading us), output for the virtual
        // speaker (an app writing to us) — so our own activity is not counted.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange(isInUse(id, scope: readScope))
        }
        let status = AudioObjectAddPropertyListenerBlock(
            id, &addr, DispatchQueue.global(qos: .userInitiated), block)
        guard status == noErr else { return nil }
        return UsageObserver(id: id, block: block, addr: addr)
    }

    public static func removeUsageObserver(_ observer: UsageObserver) {
        var addr = observer.addr
        AudioObjectRemovePropertyListenerBlock(
            observer.id, &addr, DispatchQueue.global(qos: .userInitiated), observer.block)
    }

    // MARK: - Hardware-wide observation

    /// Token for a system-object property listener; retain it and pass to
    /// `removeHardwareObserver` to stop.
    public final class HardwareObserver {
        let block: AudioObjectPropertyListenerBlock
        var addr: AudioObjectPropertyAddress
        init(block: @escaping AudioObjectPropertyListenerBlock,
             addr: AudioObjectPropertyAddress) {
            self.block = block
            self.addr = addr
        }
    }

    /// Observes a hardware-level property on the system object. Use with
    /// `kAudioHardwarePropertyDevices` (device plugged/unplugged/hidden) or
    /// `kAudioHardwarePropertyDefault{Input,Output}Device`. The handler is
    /// invoked on a background CoreAudio queue.
    public static func addHardwareObserver(
        _ selector: AudioObjectPropertySelector,
        onChange: @escaping () -> Void
    ) -> HardwareObserver? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.global(qos: .userInitiated), block)
        guard status == noErr else { return nil }
        return HardwareObserver(block: block, addr: addr)
    }

    public static func removeHardwareObserver(_ observer: HardwareObserver) {
        var addr = observer.addr
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.global(qos: .userInitiated), observer.block)
    }

    // MARK: - private

    private static func deviceFor(selector: AudioObjectPropertySelector) -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else { return nil }
        return all().first { $0.id == id }
    }

    private static func stringProp(_ id: AudioDeviceID,
                                   _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr,
              let value = ref else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(bufList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
