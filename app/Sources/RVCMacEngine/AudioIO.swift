import CoreAudio
import Foundation
import RVCMacCore
import RVCMacRT

// MARK: - Swift wrappers over the real-time primitives (see RVCMacRT/rvc_rt.h)

/// Lock-free SPSC float ring with monotonically increasing positions.
package final class SampleRing {
    fileprivate let ptr: OpaquePointer
    package init(capacity: Int) { ptr = rvc_ring_create(Int64(capacity))! }
    deinit { rvc_ring_destroy(ptr) }

    @discardableResult
    package func write(_ src: UnsafePointer<Float>, count: Int) -> Int { Int(rvc_ring_write(ptr, src, Int64(count))) }
    @discardableResult
    package func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int { Int(rvc_ring_read(ptr, dst, Int64(count))) }
    @discardableResult
    package func skip(_ count: Int) -> Int { Int(rvc_ring_skip(ptr, Int64(count))) }
    package var available: Int { Int(rvc_ring_available(ptr)) }
    package var capacity: Int { Int(rvc_ring_capacity(ptr)) }
    package var writePosition: UInt64 { rvc_ring_write_pos(ptr) }
    package var readPosition: UInt64 { rvc_ring_read_pos(ptr) }
    package var dropped: Int { Int(rvc_ring_dropped(ptr)) }
    /// Only while no callback or worker uses the ring.
    package func reset() { rvc_ring_reset(ptr) }
}

/// Latest (stream position, host time) pair published by an audio callback.
package final class HostClock {
    fileprivate let ptr: OpaquePointer
    package init() { ptr = rvc_clock_create()! }
    deinit { rvc_clock_destroy(ptr) }
    package func publish(position: UInt64, hostTime: UInt64) { rvc_clock_publish(ptr, position, hostTime) }
    package func read() -> (position: UInt64, hostTime: UInt64)? {
        var p: UInt64 = 0, h: UInt64 = 0
        return rvc_clock_read(ptr, &p, &h) == 1 ? (p, h) : nil
    }
    package func reset() { rvc_clock_reset(ptr) }
}

package final class AtomicInt {
    fileprivate let ptr: OpaquePointer
    package init(_ v: Int = 0) { ptr = rvc_atomic_create(Int64(v))! }
    deinit { rvc_atomic_destroy(ptr) }
    package var value: Int {
        get { Int(rvc_atomic_load(ptr)) }
        set { rvc_atomic_store(ptr, Int64(newValue)) }
    }
    @discardableResult
    package func add(_ d: Int) -> Int { Int(rvc_atomic_add(ptr, Int64(d))) }
}

package enum HostTime {
    package static func now() -> UInt64 { rvc_host_now() }
    package static func ns(_ ticks: UInt64) -> Double { rvc_host_to_ns(ticks) }
    package static func ms(from a: UInt64, to b: UInt64) -> Double { rvc_host_delta_ms(a, b) }
}

// MARK: - Audio I/O

package enum AudioIOError: LocalizedError {
    case coreAudio(String, OSStatus)
    package var errorDescription: String? {
        switch self {
        case let .coreAudio(what, st): return "\(what) failed (OSStatus \(st))"
        }
    }
}

package enum DeviceEvent {
    case disconnected(String)
    case sampleRateChanged(String)
}

/// State only the output callback touches (mute ramp, underrun/resume ramps, trim splice).
private final class OutputCallbackState {
    var gain: Float = 1
    var resumeLeft = 0    // A2: ramp-up samples still to play after (re)prefill
    var spliceLeft = 0    // A3: trim crossfade samples still to play
}

/// Runs a HAL IOProc on the input device and another on the output device (they may be different devices).
///
/// Real-time rules for both callbacks: no locks, no allocation, no Objective-C/Swift object
/// lookups, no I/O. They only copy samples, touch atomics and publish timestamps.
package final class AudioIO {
    private var inputID: AudioDeviceID = 0
    private var outputID: AudioDeviceID = 0
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private static let maxFrames = 16384
    private let scratchIn = UnsafeMutablePointer<Float>.allocate(capacity: AudioIO.maxFrames)
    private let scratchOut = UnsafeMutablePointer<Float>.allocate(capacity: AudioIO.maxFrames)
    private var spliceBuf: UnsafeMutablePointer<Float>?   // A3: discarded-head scratch, sized in start()
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Captured samples at the input device rate (channel 1).
    package let inputRing = SampleRing(capacity: 192_000 * 2)
    /// Processed samples at the output device rate.
    package let outputRing = SampleRing(capacity: 192_000 * 2)
    package let inputClock = HostClock()
    package let outputClock = HostClock()

    /// Output stays silent until this many samples are queued (prevents stutter at start).
    package let outputPrefill = AtomicInt(0)
    /// The output callback drops the oldest samples when more than this many are queued.
    package let outputMaxFill = AtomicInt(Int.max)
    package let muted = AtomicInt(0)
    private let outputStarted = AtomicInt(0)

    // counters (written by callbacks / listeners, read by the worker and UI)
    package let underrunEvents = AtomicInt(0)
    package let underrunFrames = AtomicInt(0)
    package let trimFrames = AtomicInt(0)
    package let trimEvents = AtomicInt(0)
    package let overloads = AtomicInt(0)
    package let truncatedCallbacks = AtomicInt(0)

    package private(set) var inputRate: Double = 48000
    package private(set) var outputRate: Double = 48000
    package private(set) var inputLatencyMs: Double = 0
    package private(set) var outputLatencyMs: Double = 0
    package private(set) var inputBufferFrames = 0
    package private(set) var outputBufferFrames = 0

    /// Called on the main queue.
    package var onDeviceEvent: ((DeviceEvent) -> Void)?

    deinit {
        stop()
        scratchIn.deallocate()
        scratchOut.deallocate()
        spliceBuf?.deallocate()
    }

    package func start(input: AudioDeviceID, output: AudioDeviceID) throws {
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
        // silent until the engine sets real values for this session (it needs the device rate first)
        outputPrefill.value = Int.max
        outputMaxFill.value = Int.max
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
        // A2/A3: 5 ms equal-power ramps and the discarded-head scratch, allocated here once,
        // never inside the callback
        let rampLen = max(1, Int(0.005 * outputRate))
        let (fadeIn, fadeOut) = Fade.curves(rampLen)
        spliceBuf?.deallocate()
        let splice = UnsafeMutablePointer<Float>.allocate(capacity: rampLen)
        spliceBuf = splice
        // ~5 ms one-pole ramp so mute / push-to-talk never clicks
        let rampCoef = Float(1 - exp(-1 / (0.005 * outputRate)))
        st = AudioDeviceCreateIOProcIDWithBlock(&outputProc, output, nil) { _, _, _, outOutputData, inOutputTime in
            let list = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard let first = list.first else { return }
            let ch0 = max(Int(first.mNumberChannels), 1)
            var frames = Int(first.mDataByteSize) / (4 * ch0)
            if frames > maxFrames { frames = maxFrames; truncated.add(1) }
            var got = 0
            var justPrefilled = false
            if started.value == 0 && outRing.available >= prefill.value {
                started.value = 1
                cbState.resumeLeft = rampLen   // A2: ramp up after (re)prefill
                justPrefilled = true
            }
            if started.value != 0 {
                // written so it cannot overflow when the limit is Int.max
                let queued = outRing.available, limit = maxFill.value
                if queued > frames && queued - frames > limit {
                    let drop = queued - frames - limit
                    // A3: keep the head of the discarded region (the samples right after the
                    // last played one) to crossfade the splice
                    let keep = min(drop, rampLen)
                    _ = outRing.read(into: splice + (rampLen - keep), count: keep)
                    // pad the prefix with the first discarded sample so the fade always starts
                    // exactly at the old signal, even when the discarded region is short
                    let firstOld = splice[rampLen - keep]
                    for j in 0..<(rampLen - keep) { splice[j] = firstOld }
                    tFrames.add(outRing.skip(drop - keep) + keep)
                    tEvents.add(1)
                    // the ramp-up from silence is already continuous; no splice on top of it
                    cbState.spliceLeft = justPrefilled ? 0 : rampLen
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
            // A3: crossfade the splice (may span callbacks); applied before the underrun ramp
            // so a partial buffer continues the blend instead of jumping
            if cbState.spliceLeft > 0 && got > 0 {
                let n = min(cbState.spliceLeft, got)
                let base = rampLen - cbState.spliceLeft
                for j in 0..<n { sOut[j] = sOut[j] * fadeIn[base + j] + splice[base + j] * fadeOut[base + j] }
                cbState.spliceLeft -= n
            }
            if got < frames {
                // A2: ramp the partial buffer down to zero, then wait for a new prefill
                Fade.rampDownTail(sOut, got: got, ramp: rampLen, fadeOut: fadeOut)
                started.value = 0
                cbState.spliceLeft = 0
                cbState.resumeLeft = 0
                (sOut + got).update(repeating: 0, count: frames - got)
            }
            // A2: ramp up from silence after re-prefill (may span callbacks)
            if cbState.resumeLeft > 0 && got > 0 {
                cbState.resumeLeft -= Fade.rampUpHead(sOut, got: got, left: cbState.resumeLeft, ramp: rampLen, fadeIn: fadeIn)
            }
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
                let full = Int(buffer.mDataByteSize) / (4 * ch)
                let n = min(full, frames)
                if ch == 1 {
                    dst.update(from: sOut, count: n)
                    // A5: zero the tail beyond the frames we produced
                    if full > n { (dst + n).update(repeating: 0, count: full - n) }
                } else {
                    for i in 0..<n {
                        let v = sOut[i]
                        for c in 0..<ch { dst[i * ch + c] = v }
                    }
                    if full > n { (dst + n * ch).update(repeating: 0, count: (full - n) * ch) }
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

    /// Stops and destroys both IOProcs and removes the device listeners.
    /// Contract (B4): the session figures — inputRate/outputRate, inputLatencyMs/outputLatencyMs,
    /// buffer frame sizes and all counters — are deliberately kept; the live report is built
    /// after engine.stop() and still reads them. Only start() refreshes them.
    package func stop() {
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
        let inName = AudioDevices.device(for: inputID)?.name ?? tr("вход")
        let outName = AudioDevices.device(for: outputID)?.name ?? tr("выход")
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
