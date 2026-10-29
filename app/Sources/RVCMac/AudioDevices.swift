import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device(for: $0) }
    }

    static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let name = string(id, kAudioObjectPropertyName) else { return nil }
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
        return AudioDevice(id: id, uid: uid, name: name,
                           inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                           outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
                           sampleRate: sampleRate(id))
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Virtual devices (BlackHole, Loopback, aggregate-free drivers) can route output back to input.
    static func isVirtual(_ id: AudioObjectID) -> Bool {
        uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual
    }

    static func isAlive(_ id: AudioObjectID) -> Bool { (uint32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0 }

    static func bufferFrameSize(_ id: AudioObjectID) -> Int { Int(uint32(id, kAudioDevicePropertyBufferFrameSize) ?? 0) }

    /// Device latency + safety offset + latency of the first stream, in frames, as Core Audio reports them.
    /// The IO buffer itself is not included: the engine measures that part directly from timestamps.
    static func latencyFrames(_ id: AudioObjectID, input: Bool) -> Int {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var total = Int(uint32(id, kAudioDevicePropertyLatency, scope) ?? 0)
        total += Int(uint32(id, kAudioDevicePropertySafetyOffset, scope) ?? 0)
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let s = streams.first {
                total += Int(uint32(s, kAudioStreamPropertyLatency) ?? 0)
            }
        }
        return total
    }

    static func sampleRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}
