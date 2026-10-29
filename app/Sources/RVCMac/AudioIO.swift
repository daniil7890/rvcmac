import CoreAudio
import Foundation
import RVCMacRT

// MARK: - Swift wrappers over the real-time primitives (see RVCMacRT/rvc_rt.h)

/// Lock-free SPSC float ring with monotonically increasing positions.
final class SampleRing {
    fileprivate let ptr: OpaquePointer
    init(capacity: Int) { ptr = rvc_ring_create(Int64(capacity))! }
    deinit { rvc_ring_destroy(ptr) }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int { Int(rvc_ring_write(ptr, src, Int64(count))) }
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int { Int(rvc_ring_read(ptr, dst, Int64(count))) }
    @discardableResult
    func skip(_ count: Int) -> Int { Int(rvc_ring_skip(ptr, Int64(count))) }
    var available: Int { Int(rvc_ring_available(ptr)) }
    var capacity: Int { Int(rvc_ring_capacity(ptr)) }
    var writePosition: UInt64 { rvc_ring_write_pos(ptr) }
    var readPosition: UInt64 { rvc_ring_read_pos(ptr) }
    var dropped: Int { Int(rvc_ring_dropped(ptr)) }
    /// Only while no callback or worker uses the ring.
    func reset() { rvc_ring_reset(ptr) }
}

/// Latest (stream position, host time) pair published by an audio callback.
final class HostClock {
    fileprivate let ptr: OpaquePointer
    init() { ptr = rvc_clock_create()! }
    deinit { rvc_clock_destroy(ptr) }
    func publish(position: UInt64, hostTime: UInt64) { rvc_clock_publish(ptr, position, hostTime) }
    func read() -> (position: UInt64, hostTime: UInt64)? {
        var p: UInt64 = 0, h: UInt64 = 0
        return rvc_clock_read(ptr, &p, &h) == 1 ? (p, h) : nil
    }
    func reset() { rvc_clock_reset(ptr) }
}

final class AtomicInt {
    fileprivate let ptr: OpaquePointer
    init(_ v: Int = 0) { ptr = rvc_atomic_create(Int64(v))! }
    deinit { rvc_atomic_destroy(ptr) }
    var value: Int {
        get { Int(rvc_atomic_load(ptr)) }
        set { rvc_atomic_store(ptr, Int64(newValue)) }
    }
    @discardableResult
    func add(_ d: Int) -> Int { Int(rvc_atomic_add(ptr, Int64(d))) }
}

enum HostTime {
    static func now() -> UInt64 { rvc_host_now() }
    static func ns(_ ticks: UInt64) -> Double { rvc_host_to_ns(ticks) }
    static func ms(from a: UInt64, to b: UInt64) -> Double { rvc_host_delta_ms(a, b) }
}

// MARK: - Audio I/O

enum AudioIOError: LocalizedError {
    case coreAudio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case let .coreAudio(what, st): return "\(what) failed (OSStatus \(st))"
        }
    }
}

enum DeviceEvent {
    case disconnected(String)
    case sampleRateChanged(String)
}

/// State only the output callback touches (mute ramp).
private final class OutputCallbackState {
    var gain: Float = 1
}

/// Runs a HAL IOProc on the input device and another on the output device (they may be different devices).
///
/// Real-time rules for both callbacks: no locks, no allocation, no Objective-C/Swift object
/// lookups, no I/O. They only copy samples, touch atomics and publish timestamps.
final class AudioIO {
    private var inputID: AudioDeviceID = 0
    private var outputID: AudioDeviceID = 0
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private static let maxFrames = 16384
    private let scratchIn = UnsafeMutablePointer<Float>.allocate(capacity: AudioIO.maxFrames)
    private let scratchOut = UnsafeMutablePointer<Float>.allocate(capacity: AudioIO.maxFrames)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Captured samples at the input device rate (channel 1).
    let inputRing = SampleRing(capacity: 192_000 * 2)
    /// Processed samples at the output device rate.
    let outputRing = SampleRing(capacity: 192_000 * 2)
    let inputClock = HostClock()
    let outputClock = HostClock()

    /// Output stays silent until this many samples are queued (prevents stutter at start).
    let outputPrefill = AtomicInt(0)
    /// The output callback drops the oldest samples when more than this many are queued.
    let outputMaxFill = AtomicInt(Int.max)
    let muted = AtomicInt(0)
    private let outputStarted = AtomicInt(0)

    // counters (written by callbacks / listeners, read by the worker and UI)
    let underrunEvents = AtomicInt(0)
    let underrunFrames = AtomicInt(0)
    let trimFrames = AtomicInt(0)
    let trimEvents = AtomicInt(0)
    let overloads = AtomicInt(0)
    let truncatedCallbacks = AtomicInt(0)

    private(set) var inputRate: Double = 48000
    private(set) var outputRate: Double = 48000
    private(set) var inputLatencyMs: Double = 0
    private(set) var outputLatencyMs: Double = 0
    private(set) var inputBufferFrames = 0
    private(set) var outputBufferFrames = 0

    /// Called on the main queue.
    var onDeviceEvent: ((DeviceEvent) -> Void)?

    deinit {
        stop()
        scratchIn.deallocate()
        scratchOut.deallocate()
    }

    func start(input: AudioDeviceID, output: AudioDeviceID) throws {
        stop()
        inputID = input
        outputID = output
        inputRate = AudioDevices.sampleRate(input)
        outputRate = AudioDevices.sampleRate(output)
        guard inputRate > 0, outputRate > 0 else { throw AudioIOError.coreAudio("Read nominal sample rate", -1) }
        inputLatencyMs = Double(AudioDevices.latencyFrames(input, input: true)) / inputRate * 1000
        outputLatencyMs = Double(AudioDevices.latencyFrames(output, input: false)) / outputRate * 1000
        inputBufferFrames = AudioDevices.bufferFrameSize(input)
        outputBufferFrames = AudioDevices.bufferFrameSize(output)

        inputRing.reset()
        outputRing.reset()
        inputClock.reset()
        outputClock.reset()
        outputStarted.value = 0
        for c in [underrunEvents, underrunFrames, trimFrames, trimEvents, overloads, truncatedCallbacks] { c.value = 0 }

        // Captured as plain references: no `self` lookups (weak or strong) inside the callbacks.
        let inRing = inputRing, inClock = inputClock, sIn = scratchIn, truncated = truncatedCallbacks
        let maxFrames = AudioIO.maxFrames
        var st = AudioDeviceCreateIOProcIDWithBlock(&inputProc, input, nil) { _, inInputData, inInputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = list.first, let data = first.mData else { return }
            let ch = max(Int(first.mNumberChannels), 1)
            var frames = Int(first.mDataByteSize) / (4 * ch)
            if frames > maxFrames { frames = maxFrames; truncated.add(1) }
            let ts = inInputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : rvc_host_now()
            inClock.publish(position: inRing.writePosition, hostTime: host)
            let src = data.assumingMemoryBound(to: Float.self)
            if ch == 1 {
                inRing.write(src, count: frames)
            } else {
                for i in 0..<frames { sIn[i] = src[i * ch] } // channel 1 of an interleaved stream
                inRing.write(sIn, count: frames)
            }
        }
        guard st == noErr else { throw AudioIOError.coreAudio("Create input IOProc", st) }

        let outRing = outputRing, outClock = outputClock, sOut = scratchOut
        let started = outputStarted, prefill = outputPrefill, maxFill = outputMaxFill, mute = muted
        let uEvents = underrunEvents, uFrames = underrunFrames, tFrames = trimFrames, tEvents = trimEvents
        let cbState = OutputCallbackState()
        // ~5 ms one-pole ramp so mute / push-to-talk never clicks
        let rampCoef = Float(1 - exp(-1 / (0.005 * outputRate)))
        st = AudioDeviceCreateIOProcIDWithBlock(&outputProc, output, nil) { _, _, _, outOutputData, inOutputTime in
            let list = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard let first = list.first else { return }
            let ch0 = max(Int(first.mNumberChannels), 1)
            var frames = Int(first.mDataByteSize) / (4 * ch0)
            if frames > maxFrames { frames = maxFrames; truncated.add(1) }
            var got = 0
            if started.value == 0 && outRing.available >= prefill.value { started.value = 1 }
            if started.value != 0 {
                let excess = outRing.available - frames - maxFill.value
                if excess > 0 {
                    tFrames.add(outRing.skip(excess))
                    tEvents.add(1)
                }
                let ts = inOutputTime.pointee
                let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : rvc_host_now()
                outClock.publish(position: outRing.readPosition, hostTime: host)
                got = outRing.read(into: sOut, count: frames)
                if got < frames {
                    uEvents.add(1)
                    uFrames.add(frames - got)
                }
            }
            if got < frames { (sOut + got).update(repeating: 0, count: frames - got) }
            let target: Float = mute.value != 0 ? 0 : 1
            var g = cbState.gain
            if g != target || target != 1 {
                for i in 0..<frames {
                    g += (target - g) * rampCoef
                    sOut[i] *= g
                }
                if abs(g - target) < 1e-4 { g = target }
                cbState.gain = g
            }
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let ch = max(Int(buffer.mNumberChannels), 1)
                let dst = data.assumingMemoryBound(to: Float.self)
                let n = min(Int(buffer.mDataByteSize) / (4 * ch), frames)
                if ch == 1 {
                    dst.update(from: sOut, count: n)
                } else {
                    for i in 0..<n {
                        let v = sOut[i]
                        for c in 0..<ch { dst[i * ch + c] = v }
                    }
                }
            }
        }
        guard st == noErr else { throw AudioIOError.coreAudio("Create output IOProc", st) }

        installListeners()

        st = AudioDeviceStart(input, inputProc)
        guard st == noErr else { throw AudioIOError.coreAudio("Start input device", st) }
        st = AudioDeviceStart(output, outputProc)
        guard st == noErr else { throw AudioIOError.coreAudio("Start output device", st) }
    }

    func stop() {
        removeListeners()
        if let p = inputProc {
            AudioDeviceStop(inputID, p)
            AudioDeviceDestroyIOProcID(inputID, p)
            inputProc = nil
        }
        if let p = outputProc {
            AudioDeviceStop(outputID, p)
            AudioDeviceDestroyIOProcID(outputID, p)
            outputProc = nil
        }
    }

    // MARK: device listeners (main queue, never on the audio thread)

    private func installListeners() {
        let inName = AudioDevices.device(for: inputID)?.name ?? "вход"
        let outName = AudioDevices.device(for: outputID)?.name ?? "выход"
        var seen = Set<AudioDeviceID>()
        for (id, name, rate) in [(inputID, inName, inputRate), (outputID, outName, outputRate)] where seen.insert(id).inserted {
            listen(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                if !AudioDevices.isAlive(id) { self?.onDeviceEvent?(.disconnected(name)) }
            }
            listen(id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                let now = AudioDevices.sampleRate(id)
                if now > 0 && now != rate { self?.onDeviceEvent?(.sampleRateChanged(name)) }
            }
            listen(id, kAudioDeviceProcessorOverload) { [weak self] in self?.overloads.add(1) }
        }
    }

    private func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
            listeners.append((id, addr, block))
        }
    }

    private func removeListeners() {
        for (id, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }
}
