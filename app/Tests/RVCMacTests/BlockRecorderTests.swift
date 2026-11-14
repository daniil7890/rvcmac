import Foundation
import os
import RVCMacCore
import XCTest

final class BlockRecorderTests: XCTestCase {
    private func append(_ r: BlockRecorder, _ i: Int, latency: Bool = false) {
        var times = StageTimes()
        times[.total] = Double(i)
        let id = r.append(run: 0, t: Double(i) / 10, flags: i % 2 == 0 ? .gated : [], stages: times,
                          algorithmicMs: Double(i), solaOffset: i)
        if latency { r.setLatency(id: id, pipelineMs: Double(i) + 0.5, endToEndMs: Double(i) + 1.5) }
    }

    func testSnapshotRowsMatchLiveRows() {
        let r = BlockRecorder(capacity: 8)
        for i in 0..<5 { append(r, i, latency: true) }
        XCTAssertEqual(ReportMath.csv(r.snapshot().rows()), ReportMath.csv(r.rows()))
    }

    func testSnapshotIsIndependentOfLaterAppends() {
        let r = BlockRecorder(capacity: 8)
        for i in 0..<3 { append(r, i) }
        let snap = r.snapshot()
        let before = ReportMath.csv(snap.rows())
        for i in 3..<6 { append(r, i) }
        XCTAssertEqual(snap.rows().count, 3)
        XCTAssertEqual(ReportMath.csv(snap.rows()), before)
    }

    func testSnapshotAfterWrapKeepsNewestRows() {
        let r = BlockRecorder(capacity: 4)
        for i in 0..<10 { append(r, i, latency: true) }
        let rows = r.snapshot().rows()
        XCTAssertEqual(rows.map(\.index), [6, 7, 8, 9])
        XCTAssertEqual(ReportMath.csv(rows), ReportMath.csv(r.rows()))
    }

    func testSnapshotAfterWrapIsIndependentOfLaterAppends() {
        let r = BlockRecorder(capacity: 4)
        for i in 0..<10 { append(r, i, latency: true) }
        let snap = r.snapshot()
        let before = ReportMath.csv(snap.rows())
        for i in 10..<14 { append(r, i, latency: true) }   // overwrites the snapshot's slots
        XCTAssertEqual(ReportMath.csv(snap.rows()), before)
        XCTAssertEqual(snap.rows().map(\.index), [6, 7, 8, 9])
    }

    func testSnapshotLastLimitsToNewest() {
        let r = BlockRecorder(capacity: 4)
        for i in 0..<10 { append(r, i) }
        XCTAssertEqual(r.snapshot().rows(last: 2).map(\.index), [8, 9])
    }

    func testTryLockSkipsAppendWhileTheLockIsHeld() {
        let lock = OSAllocatedUnfairLock()
        let r = BlockRecorder(capacity: 8)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread {
            lock.withLock {
                held.signal()
                release.wait()
            }
        }.start()
        held.wait()
        let skipped = lock.withLockIfAvailable {
            r.append(run: 0, t: 0, flags: [], stages: StageTimes(), algorithmicMs: 0, solaOffset: 0)
        }
        XCTAssertNil(skipped)
        release.signal()
        lock.withLock {}   // the holder is done, so the recorder is free again
        XCTAssertEqual(r.total, 0)
        let id = lock.withLockIfAvailable {
            r.append(run: 0, t: 0, flags: [], stages: StageTimes(), algorithmicMs: 0, solaOffset: 0)
        }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(r.total, 1)
    }

    func testSkippedAppendDoesNotCorruptLatencyOfAnyRow() {
        let lock = OSAllocatedUnfairLock()
        let r = BlockRecorder(capacity: 4)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var pending: [(id: Int, ms: Double)] = []
        // the worker contract: a latency update is queued only when the append happened
        func appendBlock() {
            let id = lock.withLockIfAvailable {
                r.append(run: 0, t: 0, flags: [], stages: StageTimes(), algorithmicMs: 0, solaOffset: 0)
            }
            if let id { pending.append((id, Double(id) + 0.5)) }
        }
        for _ in 0..<6 { appendBlock() }   // ids 0..5, already wrapped over capacity 4
        Thread {
            lock.withLock {
                held.signal()
                release.wait()
            }
        }.start()
        held.wait()
        appendBlock()   // the exporter holds the lock: skipped, no id may be queued
        release.signal()
        lock.withLock {}
        for _ in 0..<3 { appendBlock() }   // ids 6..8
        XCTAssertEqual(pending.count, 9)
        lock.withLock {
            for p in pending { r.setLatency(id: p.id, pipelineMs: p.ms, endToEndMs: p.ms + 1) }
        }
        let rows = r.rows()
        XCTAssertEqual(rows.map(\.index), [5, 6, 7, 8])
        for row in rows {
            XCTAssertEqual(row.pipelineMs, Double(row.index) + 0.5)
            XCTAssertEqual(row.endToEndMs, Double(row.index) + 1.5)
        }
        // a stale id must stay rejected: without the guard it would overwrite slot 0 (id 8)
        r.setLatency(id: 0, pipelineMs: -1, endToEndMs: -1)
        for row in r.rows() {
            XCTAssertEqual(row.pipelineMs, Double(row.index) + 0.5)
            XCTAssertEqual(row.endToEndMs, Double(row.index) + 1.5)
        }
    }

    func testCountersDecodeFromOldReportsWithoutNewKeys() throws {
        let json = #"{"blocks":5,"underrunEvents":2,"errors":0}"#
        let c = try ReportMath.decoder().decode(Report.Counters.self, from: Data(json.utf8))
        XCTAssertEqual(c.blocks, 5)
        XCTAssertEqual(c.underrunEvents, 2)
        XCTAssertEqual(c.droppedRows, 0)
        XCTAssertEqual(c.trimEvents, 0)
        XCTAssertEqual(c.unresolvedLatency, 0)
        XCTAssertEqual(c.skippedInputMs, 0)
    }

    func testOldReportWithoutResourceTraceDecodes() throws {
        let report = Report(kind: .live, createdAt: Date(), appVersion: "test",
                            system: Report.SystemInfo(macOS: "14", machine: "m", chip: "c", memoryGB: 16,
                                                      thermalStart: "nominal", thermalEnd: "nominal", lowPowerMode: false),
                            model: Report.ModelInfo(name: "v", version: "1", sampleRate: 40000, indexVectors: nil),
                            config: Report.ConfigInfo(compute: "CPU", blockMs: 100, extraMs: 500, crossfadeMs: 50,
                                                      inputRate: 48000, outputRate: 48000, pitch: 12, indexRatio: 0.75,
                                                      protect: 0.33, gateDB: -60),
                            coldStart: nil, stages: [:], latency: nil, runs: [], counters: Report.Counters(),
                            resources: nil, notes: [])
        let data = try ReportMath.encoder().encode(report)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "resourceTrace")
        var counters = try XCTUnwrap(obj["counters"] as? [String: Any])
        counters.removeValue(forKey: "trimEvents")
        obj["counters"] = counters
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try ReportMath.decoder().decode(Report.self, from: old)
        XCTAssertNil(decoded.resourceTrace)
        XCTAssertEqual(decoded.counters.trimEvents, 0)
    }
}