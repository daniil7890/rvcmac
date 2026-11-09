import Foundation
import RVCMacRT

/// Turns device input from the ring into 16 kHz blocks for the inference thread, and limits how far it may fall behind.
package final class InputAssembler {
    package static let chunk = 4096
    private static let spliceFade = 80   // 5 ms at 16 kHz

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
        accCap = block16 * 4 + tmp16Cap   // the limit below leaves room for one more chunk, so nothing is cut without the crossfade
        acc = .allocate(capacity: accCap)
    }

    deinit {
        tmp.deallocate()
        tmp16.deallocate()
        acc.deallocate()
    }

    /// The oldest `block16` samples. Valid until the next call that changes the queue.
    package var block: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: acc, count: block16) }

    /// Moves everything waiting in the ring into the queue, between blocks, so an overload is handled here and not by the ring.
    package func pull(from ring: SampleRing) {
        for _ in 0...(ring.capacity / Self.chunk) {
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
            limitBacklog()
            if n < Self.chunk { return }
        }
    }

    /// If we fell far behind, skips the oldest audio instead of growing latency forever.
    /// The join is a short crossfade from the audio that would have played next.
    private func limitBacklog() {
        guard count > block16 * 4 else { return }
        let drop = count - block16 * 2
        let fade = min(Self.spliceFade, drop, count - drop)
        for i in 0..<fade {
            let t = (Float(i) + 0.5) / Float(fade) * .pi / 2
            acc[drop + i] = acc[drop + i] * sinf(t) + acc[i] * cosf(t)
        }
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
