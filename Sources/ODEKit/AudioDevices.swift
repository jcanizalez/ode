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
        return ids.map { id in
            Device(id: id,
                   uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "",
                   name: stringProp(id, kAudioObjectPropertyName) ?? "Unknown",
                   hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                   hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0)
        }
    }

    public static func find(name: String) -> Device? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? all().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    public static func defaultOutput() -> Device? {
        deviceFor(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func defaultInput() -> Device? {
        deviceFor(selector: kAudioHardwarePropertyDefaultInputDevice)
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
