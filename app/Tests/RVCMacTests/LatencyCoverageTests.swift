import RVCMacCore
import XCTest

final class LatencyCoverageTests: XCTestCase {
    private func recorder(resolved: Int, total: Int) -> BlockRecorder {
        let r = BlockRecorder(capacity: max(20, total + 1))
        for i in 0..<total {
            let id = r.append(run: 0, t: Double(i) / 10, flags: [], stages: StageTimes(), algorithmicMs: 135, solaOffset: 0)
            if i < resolved { r.setLatency(id: id, pipelineMs: 70, endToEndMs: 255) }
        }
        return r
    }

    func testCoverageMarksP99UnreliableWhenUnresolvedAtLeastOnePercent() {
        let l = ReportMath.latency(recorder(resolved: 98, total: 100).rows(), deviceInputMs: 50, deviceOutputMs: 0)
        XCTAssertEqual(l.latencyCoverage ?? 0, 0.98, accuracy: 1e-9)
        XCTAssertEqual(l.unreliablePercentiles, ["p99"])
    }

    func testFullCoverageMarksNothing() {
        let l = ReportMath.latency(recorder(resolved: 10, total: 10).rows(), deviceInputMs: 50, deviceOutputMs: 0)
        XCTAssertEqual(l.latencyCoverage ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertNil(l.unreliablePercentiles)
    }

    func testHalfCoverageMarksP50AndUp() {
        let l = ReportMath.latency(recorder(resolved: 5, total: 10).rows(), deviceInputMs: 50, deviceOutputMs: 0)
        XCTAssertEqual(l.unreliablePercentiles, ["p50", "p95", "p99"])
    }

    func testEmptyRowsHaveFullCoverage() {
        let l = ReportMath.latency([], deviceInputMs: 50, deviceOutputMs: 0)
        XCTAssertEqual(l.latencyCoverage ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertNil(l.unreliablePercentiles)
    }

    func testBoundaryCoverage() {
        let l95 = ReportMath.latency(recorder(resolved: 95, total: 100).rows(), deviceInputMs: 0, deviceOutputMs: 0)
        XCTAssertEqual(l95.unreliablePercentiles, ["p95", "p99"])
        let l99 = ReportMath.latency(recorder(resolved: 99, total: 100).rows(), deviceInputMs: 0, deviceOutputMs: 0)
        XCTAssertEqual(l99.unreliablePercentiles, ["p99"])
    }

    func testOldLatencySummaryDecodesWithoutCoverage() throws {
        let d = #"{"count":0,"min":0,"max":0,"mean":0,"p50":0,"p95":0,"p99":0}"#
        let json = """
        {"pipeline":\(d),"algorithmic":\(d),"deviceInputMs":0,"deviceOutputMs":0,"endToEnd":\(d)}
        """
        let l = try ReportMath.decoder().decode(Report.LatencySummary.self, from: Data(json.utf8))
        XCTAssertNil(l.latencyCoverage)
        XCTAssertNil(l.unreliablePercentiles)
    }
}