import RVCMacCore
import RVCMacEngine
import XCTest

final class WarmupTests: XCTestCase {
    func testWarmupRunsSilenceBlocksAndResets() throws {
        var calls = 0
        var sawNonZero = false
        var resetAtCall = -1
        try Warmup.run(blocks: 3, block16: 1600,
                       process: { ptr, times in
                           calls += 1
                           for i in 0..<1600 where ptr[i] != 0 { sawNonZero = true }
                           times[.total] = 30
                       },
                       reset: { resetAtCall = calls })
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(sawNonZero)
        XCTAssertEqual(resetAtCall, 3)   // reset strictly after the last block
    }

    func testWarmupPropagatesErrorWithoutReset() {
        struct E: Error {}
        var resetCalled = false
        XCTAssertThrowsError(try Warmup.run(blocks: 3, block16: 16,
                                            process: { _, _ in throw E() },
                                            reset: { resetCalled = true }))
        XCTAssertFalse(resetCalled)
    }

    func testWarmupErrorOnMiddleBlockStopsAndSkipsReset() {
        struct E: Error {}
        var calls = 0
        var resetCalled = false
        XCTAssertThrowsError(try Warmup.run(blocks: 3, block16: 16,
                                            process: { _, _ in
                                                calls += 1
                                                if calls == 2 { throw E() }
                                            },
                                            reset: { resetCalled = true }))
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(resetCalled)
    }

    func testFirstBlockAfterWarmupIsNotCold() throws {
        // cold-model simulation: the first inference is slow, later ones fast. The warmup
        // must absorb the cold call so the first real block after the swap is fast.
        var calls = 0
        let process: (UnsafeBufferPointer<Float>, inout StageTimes) throws -> Void = { _, times in
            calls += 1
            times[.total] = calls == 1 ? 500 : 30
        }
        try Warmup.run(blocks: 3, block16: 1600, process: process, reset: {})
        var times = StageTimes()
        let silence = [Float](repeating: 0, count: 1600)
        _ = try silence.withUnsafeBufferPointer { try process($0, &times) }
        XCTAssertEqual(calls, 4)
        XCTAssertLessThan(times[.total], 100)
    }
}