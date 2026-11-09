import Foundation
import RVCMacRT

/// Turns device input from the ring into 16 kHz blocks for the inference thread, and limits how far it may fall behind.
package final class InputAssembler {
    package static let chunk = 4096

    package let block16: Int
    private let resampler: Resampler
    private let tmp: UnsafeMutablePointer<Float>
    private let tmp16: UnsafeMutablePointer<Float>
    private let tmp16Cap: Int
    private let acc: UnsafeMutablePointer<Float>
    private let accCap: Int
    private let skipped: AtomicInt
    private var resampleMs = 0.0

    package private(set) var count = 0
    private var abs16 = 0.0   // cumulative 16 kHz index of acc[0]

    package init(inputRate: Double, block16: Int, skipped: AtomicInt) {
        self.block16 = block16
        self.skipped = skipped
        resampler = Resampler(from: inputRate, to: 16000)
        tmp = .allocate(capacity: Self.chunk)
        tmp16Cap = resampler.maxOutput(for: Self.chunk)
        tmp16 = .allocate(capacity: tmp16Cap)
        accCap = max(block16 * 6, tmp16Cap * 2)
        acc = .allocate(capacity: accCap)
    }

    deinit {
        tmp.deallocate()
        tmp16.deallocate()
        acc.deallocate()
    }

    /// The oldest `block16` samples. Valid until the next call that changes the queue.
    package var block: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: acc, count: block16) }

    /// Moves input from the ring into the queue.
    package func pull(from ring: SampleRing) {
        let n = ring.read(into: tmp, count: Self.chunk)
        guard n > 0 else { return }
        let t0 = HostTime.now()
        let m = resampler.stream(UnsafeBufferPointer(start: tmp, count: n), into: tmp16, capacity: tmp16Cap)
        resampleMs += HostTime.ms(from: t0, to: HostTime.now())
        if count + m > accCap {
            let drop = count + m - accCap
            skipped.add(min(drop, count))
            dropFront(drop)
        }
        (acc + count).update(from: tmp16, count: m)
        count += m
    }

    /// If we fell far behind, skip old audio instead of growing latency forever.
    package func limitBacklog() {
        guard count > block16 * 4 else { return }
        let drop = count - block16 * 2
        skipped.add(drop)
        dropFront(drop)
    }

    /// Removes the oldest block and returns the 16 kHz position just after it.
    @discardableResult
    package func consumeBlock() -> Double {
        let end = abs16 + Double(block16)
        dropFront(block16)
        return end
    }

    /// Resampling time since the last call.
    package func takeResampleMs() -> Double {
        defer { resampleMs = 0 }
        return resampleMs
    }

    private func dropFront(_ n: Int) {
        let n = min(n, count)
        guard n > 0 else { return }
        memmove(acc, acc + n, (count - n) * MemoryLayout<Float>.size)
        count -= n
        abs16 += Double(n)
    }
}
