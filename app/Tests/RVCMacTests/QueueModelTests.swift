import RVCMacCore
import XCTest

final class QueueModelTests: XCTestCase {
    private let config = QueueModel.Config(blockMs: 100, inputRate: 48000, inputBufferFrames: 480,
                                           outputRate: 48000, outputBufferFrames: 480,
                                           blockOut: 4800, prefill: 2400, maxFill: 7200)

    func testFastBlocksPlayWithoutUnderrun() {
        let r = QueueModel.run(processingMs: [Double](repeating: 20, count: 50), config: config)
        XCTAssertEqual(r.underrunEvents, 0)
        XCTAssertEqual(r.trimEvents, 0)
        XCTAssertEqual(r.blocks.map(\.inputWaitMs).max(), 0)
        // the first block plays right after it is written: 20 ms of processing plus at most one device buffer
        XCTAssertEqual(r.blocks[0].pipelineMs, 30, accuracy: 10.001)
    }

    func testOverloadBuildsInputWaitAndUnderruns() {
        let r = QueueModel.run(processingMs: [Double](repeating: 150, count: 20), config: config)
        XCTAssertGreaterThan(r.underrunEvents, 0)
        XCTAssertEqual(r.blocks[19].inputWaitMs, 19 * 50, accuracy: 1)
        XCTAssertGreaterThan(r.blocks[19].pipelineMs, r.blocks[1].pipelineMs)
    }

    func testBurstIsTrimmedDownToTheLimit() {
        var times = [Double](repeating: 10, count: 30)
        times[5] = 450 // later blocks arrive in a burst and exceed the output queue limit
        let r = QueueModel.run(processingMs: times, config: config)
        XCTAssertGreaterThan(r.trimEvents, 0)
        XCTAssertGreaterThan(r.trimFrames, 0)
    }

    func testEmptyInput() {
        let r = QueueModel.run(processingMs: [], config: config)
        XCTAssertEqual(r.underrunEvents, 0)
        XCTAssertTrue(r.blocks.isEmpty)
    }

    private func avgQueue(_ r: QueueModel.Result, from: Double, to: Double) -> Double {
        let s = r.queueTrace.filter { $0.tMs >= from && $0.tMs < to }
        guard !s.isEmpty else { return .nan }
        return s.map(\.queueMs).reduce(0, +) / Double(s.count)
    }

    func testUnderrunWaitsForNewPrefill() {
        var times = [Double](repeating: 20, count: 100)
        times[20] = 600   // a stall empties the queue mid-run
        let r = QueueModel.run(processingMs: times, config: config)
        XCTAssertGreaterThan(r.underrunEvents, 0)
        XCTAssertTrue(r.queueTrace.contains { $0.queueMs == 0 })   // the queue really emptied
        XCTAssertTrue(r.blocks[99].pipelineMs.isFinite)             // playback recovered
        // after the underrun the queue must reach prefill again before playback resumes
        let prefillMs = Double(config.prefill) / config.outputRate * 1000
        let zero = r.queueTrace.firstIndex { $0.queueMs == 0 }!
        let resumed = r.queueTrace[zero...].firstIndex { $0.queueMs >= prefillMs }!
        XCTAssertGreaterThan(resumed, zero)
    }

    func testQueueLevelAroundUnderrun() {
        // 60 s at b100, a 500 ms stall at t = 10 s. Two worker regimes: faster than
        // real time (CPU-like) and exactly real time. Prints the level table for BENCHMARKS.
        let n = 600
        for (label, proc, jitter) in [("RTF 0.36", 36.0, false), ("RTF 1.0", 100.0, false), ("RTF 1.0 ±1 ms", 100.0, true)] {
            var times = [Double](repeating: proc, count: n)
            if jitter { for b in 0..<n { times[b] += b % 2 == 0 ? 1.0 : -1.0 } }   // zero-mean knife-edge jitter
            times[100] += 500
            let r = QueueModel.run(processingMs: times, config: config)
            XCTAssertGreaterThan(r.underrunEvents, 0, label)
            let before = avgQueue(r, from: 8000, to: 10000)
            let after = avgQueue(r, from: 11000, to: 12000)
            let later = avgQueue(r, from: 40000, to: 42000)
            print(String(format: "QUEUE %@: before=%.1f ms, right after=%.1f ms, +30 s=%.1f ms, underruns=%d, trims=%d",
                         label, before, after, later, r.underrunEvents, r.trimEvents))
            if proc < 100 {
                // the catch-up burst after the stall is trimmed, and the queue phase
                // shifts up and stays there: trim never fires again in steady state
                XCTAssertGreaterThan(r.trimEvents, 0, label)
                XCTAssertGreaterThan(later, before + 20, label)
                XCTAssertEqual(later, after, accuracy: 5, label)
            } else {
                // at real time there is no sustained catch-up: trim never fires,
                // the queue keeps its prefill phase even with jitter
                XCTAssertEqual(r.trimEvents, 0, label)
                XCTAssertEqual(later, before, accuracy: 10, label)
            }
        }
    }

    func testDegenerateConfigDoesNotHang() {
        let tiny = QueueModel.Config(blockMs: 100, inputRate: 48000, inputBufferFrames: 480,
                                     outputRate: 48000, outputBufferFrames: 480,
                                     blockOut: 4800, prefill: 100_000, maxFill: 7200)
        let r = QueueModel.run(processingMs: [20, 20], config: tiny)   // prefill beyond the whole stream
        XCTAssertEqual(r.underrunEvents, 0)
        let nan = QueueModel.run(processingMs: [.nan], config: config)
        XCTAssertEqual(nan.underrunEvents, 0)
    }
}
