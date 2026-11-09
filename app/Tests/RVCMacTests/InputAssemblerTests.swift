import RVCMacEngine
import XCTest

final class InputAssemblerTests: XCTestCase {
    private let block = 1600

    private func make(samples: Int) -> (SampleRing, InputAssembler, AtomicInt) {
        let ring = SampleRing(capacity: 64000)
        let skipped = AtomicInt(0)
        let input = InputAssembler(inputRate: 16000, block16: block, skipped: skipped)
        let ramp = (0..<samples).map { Float($0) / Float(samples) }
        ramp.withUnsafeBufferPointer { XCTAssertEqual(ring.write($0.baseAddress!, count: samples), samples) }
        return (ring, input, skipped)
    }

    func testNormalBacklogIsKept() {
        let (ring, input, skipped) = make(samples: block * 3)
        input.pull(from: ring)
        XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(skipped.value, 0)
        XCTAssertGreaterThan(input.count, block * 2)
    }

    func testOverloadDrainsTheRingAndKeepsTheNewestAudio() {
        let samples = block * 10
        let (ring, input, skipped) = make(samples: samples)
        input.pull(from: ring)
        XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(ring.dropped, 0)
        XCTAssertGreaterThan(skipped.value, 0)
        XCTAssertLessThanOrEqual(input.count, block * 4)
        // past the 80-sample join the queue holds the newest audio, not the oldest
        XCTAssertEqual(input.block[100], Float(samples - input.count + 100) / Float(samples), accuracy: 0.03)
    }
}
