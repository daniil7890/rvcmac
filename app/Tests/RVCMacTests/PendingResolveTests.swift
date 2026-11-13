import RVCMacEngine
import XCTest

final class PendingResolveTests: XCTestCase {
    func testNoTrimResolvesWithTheAnchor() {
        let d = PendingResolve.decide(clock: (position: 1000, hostTime: 500), trims: 3, lastTrims: 3)
        guard case .resolve(let p, let t) = d else { return XCTFail("expected resolve") }
        XCTAssertEqual(p, 1000)
        XCTAssertEqual(t, 500)
    }

    func testNoClockWaits() {
        let d = PendingResolve.decide(clock: nil, trims: 3, lastTrims: 3)
        guard case .wait = d else { return XCTFail("expected wait") }
    }

    func testNoClockWaitsEvenWhenTrimCounterChanged() {
        // wait must win over discard: consuming the counter without a clock would
        // bring the original race back for entries added before the first publish
        let d = PendingResolve.decide(clock: nil, trims: 4, lastTrims: 3)
        guard case .wait = d else { return XCTFail("expected wait") }
    }

    func testTrimBetweenReadsDiscardsPending() {
        // the race scenario: the clock was read before the trim (stale anchor),
        // the trim counter after it — the pending entries must not be resolved
        let d = PendingResolve.decide(clock: (position: 1000, hostTime: 500), trims: 4, lastTrims: 3)
        guard case .discard = d else { return XCTFail("expected discard") }
    }

    func testAfterDiscardTheNextIterationResolves() {
        let first = PendingResolve.decide(clock: (position: 1000, hostTime: 500), trims: 4, lastTrims: 3)
        guard case .discard = first else { return XCTFail("expected discard") }
        // the caller updates lastTrims and skips; the next iteration reads a fresh post-trim clock
        let second = PendingResolve.decide(clock: (position: 9000, hostTime: 900), trims: 4, lastTrims: 4)
        guard case .resolve(let p, _) = second else { return XCTFail("expected resolve") }
        XCTAssertEqual(p, 9000)
    }
}