import CoreAudio
import Foundation
import os

/// Single-producer / single-consumer float FIFO guarded by an unfair lock (held only for memcpy).
final class FloatFIFO {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var readIndex = 0
    private var available = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    var count: Int { lock.withLockUnchecked { available } }

    /// Writes n samples; when full, the oldest samples are dropped.
    func write(_ src: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        lock.withLockUnchecked {
            var src = src
            var n = n
            if n > capacity { src += n - capacity; n = capacity }
            let overflow = available + n - capacity
            if overflow > 0 {
                readIndex = (readIndex + overflow) % capacity
                available -= overflow
            }
            var writeIndex = (readIndex + available) % capacity
            var remaining = n
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                (storage + writeIndex).update(from: src + (n - remaining), count: chunk)
                writeIndex = (writeIndex + chunk) % capacity
                remaining -= chunk
            }
            available += n
        }
    }

    func write(_ array: [Float]) {
        array.withUnsafeBufferPointer { if let b = $0.baseAddress { write(b, count: $0.count) } }
    }

    /// Reads up to n samples, returns how many were read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        lock.withLockUnchecked {
            let toRead = min(n, available)
            var remaining = toRead
            var out = dst
            while remaining > 0 {
                let chunk = min(remaining, capacity - readIndex)
                out.update(from: storage + readIndex, count: chunk)
                out += chunk
                readIndex = (readIndex + chunk) % capacity
                remaining -= chunk
            }
            available -= toRead
            return toRead
        }
    }

    /// Drops samples so that at most `keep` remain (oldest are discarded).
    func trim(keep: Int) {
        lock.withLockUnchecked {
            if available > keep {
                let drop = available - keep
                readIndex = (readIndex + drop) % capacity
                available = keep
            }
        }
    }

    func clear() {
        lock.withLockUnchecked { readIndex = 0; available = 0 }
    }
}

enum AudioIOError: LocalizedError {
    case coreAudio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case let .coreAudio(what, st): return "\(what) failed (OSStatus \(st))"
        }
    }
}

/// Runs a HAL IOProc on the input device and another on the output device (they may be different devices).
final class AudioIO {
    private var inputID: AudioDeviceID = 0
    private var outputID: AudioDeviceID = 0
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private let scratchIn = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private let scratchOut = UnsafeMutablePointer<Float>.allocate(capacity: 16384)

    let inputFIFO: FloatFIFO
    let outputFIFO: FloatFIFO
    private(set) var inputRate: Double = 48000
    private(set) var outputRate: Double = 48000
    /// Output gets silence until this many samples are buffered (prevents stutter at start).
    var outputPrefill = 0
    private var outputStarted = false

    init() {
        inputFIFO = FloatFIFO(capacity: 48000 * 4)
        outputFIFO = FloatFIFO(capacity: 48000 * 4)
    }

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
        inputFIFO.clear()
        outputFIFO.clear()
        outputStarted = false

        let inFIFO = inputFIFO
        let sIn = scratchIn
        var st = AudioDeviceCreateIOProcIDWithBlock(&inputProc, input, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = list.first, let data = first.mData else { return }
            let ch = max(Int(first.mNumberChannels), 1)
            let frames = min(Int(first.mDataByteSize) / (4 * ch), 16384)
            let src = data.assumingMemoryBound(to: Float.self)
            if ch == 1 {
                inFIFO.write(src, count: frames)
            } else {
                for i in 0..<frames { sIn[i] = src[i * ch] } // channel 1 of an interleaved stream
                inFIFO.write(sIn, count: frames)
            }
        }
        guard st == noErr else { throw AudioIOError.coreAudio("Create input IOProc", st) }

        let outFIFO = outputFIFO
        let sOut = scratchOut
        st = AudioDeviceCreateIOProcIDWithBlock(&outputProc, output, nil) { [weak self] _, _, _, outOutputData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard let first = list.first else { return }
            let ch0 = max(Int(first.mNumberChannels), 1)
            let frames = min(Int(first.mDataByteSize) / (4 * ch0), 16384)
            var got = 0
            if let self = self {
                if !self.outputStarted && outFIFO.count >= self.outputPrefill { self.outputStarted = true }
                if self.outputStarted { got = outFIFO.read(into: sOut, count: frames) }
            }
            if got < frames { (sOut + got).update(repeating: 0, count: frames - got) }
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let ch = max(Int(buffer.mNumberChannels), 1)
                let dst = data.assumingMemoryBound(to: Float.self)
                let n = min(Int(buffer.mDataByteSize) / (4 * ch), frames)
                for i in 0..<n {
                    let v = sOut[i]
                    for c in 0..<ch { dst[i * ch + c] = v }
                }
            }
        }
        guard st == noErr else { throw AudioIOError.coreAudio("Create output IOProc", st) }

        st = AudioDeviceStart(input, inputProc)
        guard st == noErr else { throw AudioIOError.coreAudio("Start input device", st) }
        st = AudioDeviceStart(output, outputProc)
        guard st == noErr else { throw AudioIOError.coreAudio("Start output device", st) }
    }

    func stop() {
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
}
