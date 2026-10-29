import Foundation
import RVCMacCore
import RVCMacRT
import XCTest

final class DistributionTests: XCTestCase {
    func testPercentilesInterpolate() {
        let d = Distribution.of([4, 1, 3, 2])
        XCTAssertEqual(d.count, 4)
        XCTAssertEqual(d.min, 1)
        XCTAssertEqual(d.max, 4)
        XCTAssertEqual(d.mean, 2.5, accuracy: 1e-12)
        XCTAssertEqual(d.p50, 2.5, accuracy: 1e-12)
        XCTAssertEqual(d.p95, 3.85, accuracy: 1e-12)
        XCTAssertEqual(d.p99, 3.97, accuracy: 1e-12)
    }

    func testNaNIgnoredAndEmpty() {
        XCTAssertEqual(Distribution.of([Double.nan]).count, 0)
        XCTAssertEqual(Distribution.of([Double]()).p99, 0)
        let d = Distribution.of([5, .nan, 7])
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d.p50, 6)
    }

    func testOneToHundred() {
        let d = Distribution.of((1...100).map(Double.init))
        XCTAssertEqual(d.p50, 50.5, accuracy: 1e-9)
        XCTAssertEqual(d.p99, 99.01, accuracy: 1e-9)
    }
}

final class LatencyMathTests: XCTestCase {
    func testAlgorithmicLatency() {
        // 150 ms block, 10 ms SOLA, 100 ms crossfade, no offset -> 260 ms
        XCTAssertEqual(LatencyMath.algorithmicMs(blockF: 15, solaF: 1, crossfadeF: 10, solaOffset: 0, outputRate: 48000), 260, accuracy: 1e-9)
        // the maximal SOLA offset (one 10 ms frame) brings it back to block + crossfade
        XCTAssertEqual(LatencyMath.algorithmicMs(blockF: 15, solaF: 1, crossfadeF: 10, solaOffset: 480, outputRate: 48000), 250, accuracy: 1e-9)
    }

    func testHostExtrapolation() {
        // anchor at position 48000 = 2 s; position 24000 at 48 kHz is half a second earlier
        let ns = LatencyMath.hostNs(of: 24000, anchorPosition: 48000, anchorNs: 2e9, rate: 48000)
        XCTAssertEqual(ns, 1.5e9, accuracy: 1)
        XCTAssertEqual(LatencyMath.inputPosition(from16k: 16000, inputRate: 44100), 44100, accuracy: 1e-9)
    }
}

final class RecorderTests: XCTestCase {
    func testWrapKeepsNewestAndLatencyIds() {
        let r = BlockRecorder(capacity: 3)
        var times = StageTimes()
        for i in 0..<5 {
            times[.total] = Double(i)
            let id = r.append(run: 1, t: Double(i), flags: i == 4 ? [.gated] : [], stages: times, algorithmicMs: 250, solaOffset: i)
            XCTAssertEqual(id, i)
        }
        r.setLatency(id: 0, pipelineMs: 1, endToEndMs: 1)   // already overwritten: ignored
        r.setLatency(id: 3, pipelineMs: 80, endToEndMs: 340)
        let rows = r.rows()
        XCTAssertEqual(rows.map(\.index), [2, 3, 4])
        XCTAssertEqual(rows[1].endToEndMs, 340)
        XCTAssertTrue(rows[0].endToEndMs.isNaN)
        XCTAssertTrue(rows[2].flags.contains(.gated))
        XCTAssertEqual(r.rows(last: 1).map(\.index), [4])
        // gated blocks are excluded from stage timings
        XCTAssertEqual(ReportMath.stageDistributions(rows)[Stage.total.key]?.count, 2)
    }

    func testCSVHasHeaderAndRows() {
        let r = BlockRecorder(capacity: 4)
        r.append(run: 1, t: 0, flags: [], stages: StageTimes(), algorithmicMs: 250, solaOffset: 0)
        let csv = ReportMath.csv(r.rows())
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("run,block,t_sec"))
        XCTAssertEqual(lines[0].split(separator: ",").count, lines[1].split(separator: ",", omittingEmptySubsequences: false).count)
    }
}

final class ReportTests: XCTestCase {
    private func report(block: Int, p50: Double) -> Report {
        let d = Distribution(count: 10, min: p50, max: p50, mean: p50, p50: p50, p95: p50, p99: p50)
        return Report(kind: .file, createdAt: Date(timeIntervalSince1970: 0), appVersion: "test",
                      system: .init(macOS: "15", machine: "Mac14,2", chip: "M2", memoryGB: 16, thermalStart: "nominal", thermalEnd: "nominal", lowPowerMode: false),
                      model: .init(name: "v", version: "v2", sampleRate: 40000, indexVectors: nil),
                      config: .init(compute: "ANE", blockMs: block, extraMs: 500, crossfadeMs: 100, inputRate: 16000, outputRate: 48000,
                                    pitch: 0, indexRatio: 0.5, protect: 0.33, gateDB: -60),
                      coldStart: nil, stages: [Stage.total.key: d], latency: nil, runs: [], counters: .init(), resources: nil, notes: [])
    }

    func testRoundTripWithNaN() throws {
        var r = report(block: 150, p50: 80)
        r.coldStart = .init(loadMs: 1200, firstBlockMs: .nan)
        let data = try ReportMath.encoder().encode(r)
        let back = try ReportMath.decoder().decode(Report.self, from: data)
        XCTAssertEqual(back.config.blockMs, 150)
        XCTAssertTrue(back.coldStart!.firstBlockMs.isNaN)
    }

    func testComparison() {
        let a = report(block: 150, p50: 80), b = report(block: 120, p50: 60)
        XCTAssertEqual(ReportComparison.configDifferences(a, b), ["блок, мс: 150 → 120"])
        let row = ReportComparison.rows(a, b).first { $0.metric.hasSuffix("p50") }!
        XCTAssertEqual(row.delta, -20)
        XCTAssertEqual(row.deltaPercent, -25, accuracy: 1e-9)
    }
}

final class ProfileTests: XCTestCase {
    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rvcmac-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(url: url)
        XCTAssertTrue(store.load().isEmpty)
        let p = Profile(name: "Стрим", voice: "neo", blockMs: 150, extraMs: 500, crossfadeMs: 100, compute: "ANE",
                        pitch: 4, gateDB: -55, gain: 1, indexRatio: 0.6, protect: 0.33)
        try store.save([p])
        XCTAssertEqual(store.load(), [p])
        var q = p
        q.pitch = 7
        XCTAssertFalse(p.needsReload(comparedTo: q))
        q.blockMs = 120
        XCTAssertTrue(p.needsReload(comparedTo: q))
    }
}

final class RingBufferTests: XCTestCase {
    func testOrderAcrossThreads() {
        let ring = rvc_ring_create(1000)!
        defer { rvc_ring_destroy(ring) }
        let total = 2_000_000
        let producer = Thread {
            var buf = [Float](repeating: 0, count: 333)
            var v = 0
            while v < total {
                let k = min(333, total - v)
                for i in 0..<k { buf[i] = Float((v + i) % 100_000) }
                var w = 0
                while w < k { w += Int(buf.withUnsafeBufferPointer { rvc_ring_write(ring, $0.baseAddress! + w, Int64(k - w)) }) }
                v += k
            }
        }
        producer.start()
        var got = 0
        var buf = [Float](repeating: 0, count: 257)
        var ok = true
        while got < total {
            let n = Int(buf.withUnsafeMutableBufferPointer { rvc_ring_read(ring, $0.baseAddress!, 257) })
            for i in 0..<n where buf[i] != Float((got + i) % 100_000) { ok = false }
            got += n
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(rvc_ring_read_pos(ring), UInt64(total))
    }

    func testOverflowDropsAndCounts() {
        let ring = rvc_ring_create(10)!
        defer { rvc_ring_destroy(ring) }
        let src = [Float](repeating: 1, count: 25)
        XCTAssertEqual(src.withUnsafeBufferPointer { rvc_ring_write(ring, $0.baseAddress!, 25) }, 10)
        XCTAssertEqual(rvc_ring_dropped(ring), 15)
        XCTAssertEqual(rvc_ring_skip(ring, 4), 4)
        XCTAssertEqual(rvc_ring_available(ring), 6)
        XCTAssertEqual(rvc_ring_write_pos(ring), 10)
    }

    func testClock() {
        let c = rvc_clock_create()!
        defer { rvc_clock_destroy(c) }
        var p: UInt64 = 0, h: UInt64 = 0
        XCTAssertEqual(rvc_clock_read(c, &p, &h), 0)
        rvc_clock_publish(c, 480, 123_456)
        XCTAssertEqual(rvc_clock_read(c, &p, &h), 1)
        XCTAssertEqual(p, 480)
        XCTAssertEqual(h, 123_456)
        XCTAssertGreaterThan(rvc_host_delta_ms(0, rvc_host_now()), 0)
    }
}
