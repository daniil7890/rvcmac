import RVCMacCore
import XCTest

final class NoiseGateTests: XCTestCase {
    private func feed(_ gate: inout NoiseGate, _ levels: [Float], hold: Int = 2) -> [Bool] {
        levels.map { gate.update(db: $0, threshold: -60, hysteresisDB: 6, holdBlocks: hold) }
    }

    func testStartsClosedAndOpensAtThreshold() {
        var g = NoiseGate()
        XCTAssertEqual(feed(&g, [-70, -60.5, -60]), [false, false, true])
    }

    func testLevelInsideHysteresisKeepsItOpenButDoesNotOpenIt() {
        var g = NoiseGate()
        XCTAssertFalse(feed(&g, [-63])[0])
        XCTAssertEqual(feed(&g, [-50, -63, -63, -63, -63], hold: 0), [true, true, true, true, true])
    }

    func testHoldDelaysClosing() {
        var g = NoiseGate()
        XCTAssertEqual(feed(&g, [-50, -80, -80, -80, -80]), [true, true, true, false, false])
    }

    func testSpeechDuringHoldRestartsIt() {
        var g = NoiseGate()
        XCTAssertEqual(feed(&g, [-50, -80, -50, -80, -80, -80]), [true, true, true, true, true, false])
    }

    func testResetCloses() {
        var g = NoiseGate()
        _ = feed(&g, [-50])
        g.reset()
        XCTAssertFalse(g.isOpen)
        XCTAssertFalse(feed(&g, [-80])[0])
    }
}
