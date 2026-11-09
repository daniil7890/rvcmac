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
}
