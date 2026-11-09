import RVCMacCore
import XCTest

final class EngineSessionTests: XCTestCase {
    private let a = EngineSession.Devices(inputUID: "mic", outputUID: "out", inputRate: 48000, outputRate: 48000)
    private let b = EngineSession.Devices(inputUID: "mic", outputUID: "out", inputRate: 44100, outputRate: 48000)
    private let c = EngineSession.Devices(inputUID: "other", outputUID: "out", inputRate: 48000, outputRate: 48000)

    func testSecondStartIsRefusedWhileLoading() {
        var s = EngineSession()
        XCTAssertNotNil(s.begin())
        XCTAssertNil(s.begin())
        XCTAssertTrue(s.isStarting)
    }

    func testOneEventDuringLoadRestartsOnce() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        XCTAssertTrue(s.finish(t, started: a, current: b))
        // the restart runs through a new start and has nothing left to do
        let again = s.begin()!
        XCTAssertFalse(s.finish(again, started: b, current: b))
    }

    func testTwoEventsDuringLoadRestartOnce() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        XCTAssertNil(s.begin())
        s.noteDeviceChange()
        XCTAssertTrue(s.finish(t, started: a, current: b))
        let again = s.begin()!
        XCTAssertFalse(s.finish(again, started: b, current: b))
    }

    func testDeviceChangeIsDetectedLikeARateChange() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        XCTAssertTrue(s.finish(t, started: a, current: c))
    }

    func testEventWithoutARealChangeDoesNotRestart() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        XCTAssertFalse(s.finish(t, started: a, current: a))
    }

    func testChangeWithoutAnEventDoesNotRestart() {
        var s = EngineSession()
        let t = s.begin()!
        XCTAssertFalse(s.finish(t, started: a, current: b))
    }

    func testFailedStartDoesNotRestartAndAllowsANewStart() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        XCTAssertFalse(s.finish(t, started: nil, current: b))
        XCTAssertFalse(s.isStarting)
        XCTAssertNotNil(s.begin())
    }

    func testPendingChangeDoesNotLeakIntoTheNextStart() {
        var s = EngineSession()
        let t = s.begin()!
        s.noteDeviceChange()
        s.finish(t, started: nil, current: b)
        let next = s.begin()!
        XCTAssertFalse(s.finish(next, started: a, current: b))
    }

    func testEventOutsideAStartIsNotRemembered() {
        var s = EngineSession()
        s.noteDeviceChange()
        let t = s.begin()!
        XCTAssertFalse(s.finish(t, started: a, current: b))
    }

    func testStaleTokenCannotEndANewerStart() {
        var s = EngineSession()
        let old = s.begin()!
        s.finish(old, started: a, current: a)
        let new = s.begin()!
        s.noteDeviceChange()
        XCTAssertFalse(s.finish(old, started: a, current: b))
        XCTAssertTrue(s.isStarting)
        XCTAssertTrue(s.finish(new, started: a, current: b))
    }
}
