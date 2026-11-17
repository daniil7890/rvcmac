import Foundation
import os
import RVCMacCore
import RVCMacEngine
import XCTest

final class ModelReleaserTests: XCTestCase {
    private final class Probe {
        let onDeinit: () -> Void
        init(_ onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    func testReleaseDeallocatesOffTheCallingThread() {
        let releaser = ModelReleaser(label: "test.modelRelease")
        let released = DispatchSemaphore(value: 0)
        let deinitOnMain = OSAllocatedUnfairLock(initialState: false)
        var probe: Probe? = Probe {
            deinitOnMain.withLock { $0 = Thread.isMainThread }
            released.signal()
        }
        releaser.release(probe!)
        probe = nil
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(deinitOnMain.withLock { $0 })
    }

    func testReleaseKeepsObjectAliveUntilTheQueueRuns() {
        let releaser = ModelReleaser(label: "test.modelRelease")
        let released = DispatchSemaphore(value: 0)
        weak var weakProbe: Probe?
        do {
            let probe = Probe { released.signal() }
            weakProbe = probe
            releaser.release(probe)
            XCTAssertNotNil(weakProbe)
        }
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertNil(weakProbe)
    }

    func testLogTracksAcceptedAndReleasedObjects() {
        let prev = Loc.language
        Loc.language = .ru
        defer { Loc.language = prev }
        let releaser = ModelReleaser(label: "test.modelReleaseLog")
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let released = DispatchSemaphore(value: 0)
        releaser.log = { s in
            lines.withLock { $0.append(s) }
            if s.hasPrefix("ModelReleaser: освобождено") { released.signal() }
        }
        releaser.release(NSObject(), NSObject())
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(lines.withLock { $0 }, [
            "ModelReleaser: принято 2 объектов, в очереди 2.",
            "ModelReleaser: освобождено 2 объектов, в очереди 0.",
        ])
    }
}