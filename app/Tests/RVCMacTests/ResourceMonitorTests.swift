import Foundation
import RVCMacEngine
import XCTest

final class ResourceMonitorTests: XCTestCase {
    /// Deterministic clock: the process burns 0.7 CPU-seconds per wall second (70% of one core).
    private final class Clock {
        var wall = 0.0
        var now: Date { Date(timeIntervalSince1970: wall) }
        var cpu: Double { wall * 0.7 }
        func monitor() -> ResourceMonitor {
            ResourceMonitor(now: { self.now }, cpuSeconds: { self.cpu })
        }
    }

    /// The b50 artifact: a 1.98 s late tick followed by a 0.037 s catch-up tick
    /// must not produce a 175% spike; the CPU time carries into the next sample.
    func testShortTickDoesNotSpikeCPU() {
        let clock = Clock()
        let m = clock.monitor()
        m.reset()

        clock.wall = 1.0
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)
        clock.wall = 2.98   // timer fires 1.98 s late
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)
        clock.wall = 3.017  // catch-up tick, dt = 0.037 s
        XCTAssertNil(m.sample())
        XCTAssertEqual(m.droppedSamples, 1)
        clock.wall = 4.0    // next regular tick absorbs the skipped interval
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)

        XCTAssertEqual(m.samples.count, 3)
        XCTAssertEqual(m.samples.map(\.cpuPercent).max() ?? .nan, 70, accuracy: 0.001)
        XCTAssertEqual(m.summary.droppedCpuSamples, 1)
    }

    func testSeveralShortTicksAccumulateWithoutLoss() {
        let clock = Clock()
        let m = clock.monitor()
        m.reset()
        clock.wall = 1.0
        XCTAssertNotNil(m.sample())
        clock.wall = 1.05
        XCTAssertNil(m.sample())
        clock.wall = 1.10
        XCTAssertNil(m.sample())
        clock.wall = 2.0
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)
        XCTAssertEqual(m.droppedSamples, 2)
        XCTAssertEqual(m.samples.count, 2)
    }

    func testThresholdBoundary() {
        let clock = Clock()
        let m = clock.monitor()
        m.reset()
        clock.wall = ResourceMonitor.minSampleInterval - 0.001
        XCTAssertNil(m.sample())
        clock.wall = ResourceMonitor.minSampleInterval
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)
    }

    func testResetClearsDroppedCounter() {
        let clock = Clock()
        let m = clock.monitor()
        m.reset()
        clock.wall = 0.01
        XCTAssertNil(m.sample())
        XCTAssertEqual(m.droppedSamples, 1)
        clock.wall = 1.0
        m.reset()
        XCTAssertEqual(m.droppedSamples, 0)
        XCTAssertTrue(m.samples.isEmpty)
        clock.wall = 2.0
        XCTAssertEqual(m.sample()?.cpuPercent ?? .nan, 70, accuracy: 0.001)
    }
}