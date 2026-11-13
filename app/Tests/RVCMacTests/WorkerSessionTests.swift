import Foundation
import os
import RVCMacEngine
import XCTest

final class WorkerSessionTests: XCTestCase {
    func testJoinWithoutAWorkerReturns() {
        WorkerSession().join()
    }

    func testOnlyTheNewestTokenIsCurrent() {
        let s = WorkerSession()
        let old = s.begin()
        XCTAssertTrue(s.isCurrent(old.token))
        let new = s.begin()
        XCTAssertFalse(s.isCurrent(old.token))
        XCTAssertTrue(s.isCurrent(new.token))
        old.done.signal()
        new.done.signal()
    }

    func testEndStopsTheCurrentWorker() {
        let s = WorkerSession()
        let w = s.begin()
        XCTAssertTrue(s.isCurrent(w.token))
        s.end()
        XCTAssertFalse(s.isCurrent(w.token))
        w.done.signal()
    }

    func testWorkerEndCannotStopANewerSession() {
        let s = WorkerSession()
        let old = s.begin()
        let new = s.begin()
        s.end(token: old.token)
        XCTAssertTrue(s.isCurrent(new.token))
        s.end(token: new.token)
        XCTAssertFalse(s.isCurrent(new.token))
        old.done.signal()
        new.done.signal()
    }

    func testJoinWaitsForTheWorkerToExit() {
        let s = WorkerSession()
        let w = s.begin()
        let exited = OSAllocatedUnfairLock(initialState: false)
        Thread {
            usleep(50_000)
            exited.withLock { $0 = true }
            w.done.signal()
        }.start()
        s.join()
        XCTAssertTrue(exited.withLock { $0 })
    }

    func testSlowExitIsReportedButStillJoined() {
        let s = WorkerSession()
        let w = s.begin()
        let exited = OSAllocatedUnfairLock(initialState: false)
        Thread {
            usleep(150_000)
            exited.withLock { $0 = true }
            w.done.signal()
        }.start()
        var reported = false
        s.join(timeout: .milliseconds(30)) { reported = true }
        XCTAssertTrue(reported)
        XCTAssertTrue(exited.withLock { $0 })
    }

    func testLateSignalFromAnOldSessionDoesNotEndTheNewJoin() {
        let s = WorkerSession()
        let old = s.begin()
        let new = s.begin()
        let newExited = OSAllocatedUnfairLock(initialState: false)
        Thread { usleep(30_000); old.done.signal() }.start()
        Thread {
            usleep(150_000)
            newExited.withLock { $0 = true }
            new.done.signal()
        }.start()
        s.join()
        XCTAssertTrue(newExited.withLock { $0 })
    }
}