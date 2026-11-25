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

    private func avgQueue(_ r: QueueModel.Result, from: Double, to: Double) -> Double {
        let s = r.queueTrace.filter { $0.tMs >= from && $0.tMs < to }
        guard !s.isEmpty else { return .nan }
        return s.map(\.queueMs).reduce(0, +) / Double(s.count)
    }

    func testUnderrunWaitsForNewPrefill() {
        var times = [Double](repeating: 20, count: 100)
        times[20] = 600   // a stall empties the queue mid-run
        let r = QueueModel.run(processingMs: times, config: config)
        XCTAssertGreaterThan(r.underrunEvents, 0)
        XCTAssertTrue(r.queueTrace.contains { $0.queueMs == 0 })   // the queue really emptied
        XCTAssertTrue(r.blocks[99].pipelineMs.isFinite)             // playback recovered
        // after the underrun the queue must reach prefill again before playback resumes
        let prefillMs = Double(config.prefill) / config.outputRate * 1000
        let zero = r.queueTrace.firstIndex { $0.queueMs == 0 }!
        let resumed = r.queueTrace[zero...].firstIndex { $0.queueMs >= prefillMs }!
        XCTAssertGreaterThan(resumed, zero)
    }

    func testQueueLevelAroundUnderrun() {
        // 60 s at b100, a 500 ms stall at t = 10 s. Two worker regimes: faster than
        // real time (CPU-like) and exactly real time. Prints the level table for BENCHMARKS.
        let n = 600
        for (label, proc, jitter) in [("RTF 0.36", 36.0, false), ("RTF 1.0", 100.0, false), ("RTF 1.0 ±1 ms", 100.0, true)] {
            var times = [Double](repeating: proc, count: n)
            if jitter { for b in 0..<n { times[b] += b % 2 == 0 ? 1.0 : -1.0 } }   // zero-mean knife-edge jitter
            times[100] += 500
            let r = QueueModel.run(processingMs: times, config: config)
            XCTAssertGreaterThan(r.underrunEvents, 0, label)
            let before = avgQueue(r, from: 8000, to: 10000)
            let after = avgQueue(r, from: 11000, to: 12000)
            let later = avgQueue(r, from: 40000, to: 42000)
            print(String(format: "QUEUE %@: before=%.1f ms, right after=%.1f ms, +30 s=%.1f ms, underruns=%d, trims=%d",
                         label, before, after, later, r.underrunEvents, r.trimEvents))
            if proc < 100 {
                // the catch-up burst after the stall is trimmed, and the queue phase
                // shifts up and stays there: trim never fires again in steady state
                XCTAssertGreaterThan(r.trimEvents, 0, label)
                XCTAssertGreaterThan(later, before + 20, label)
                XCTAssertEqual(later, after, accuracy: 5, label)
            } else {
                // at real time there is no sustained catch-up: trim never fires,
                // the queue keeps its prefill phase even with jitter
                XCTAssertEqual(r.trimEvents, 0, label)
                XCTAssertEqual(later, before, accuracy: 10, label)
            }
        }
    }

    func testDegenerateConfigDoesNotHang() {
        let tiny = QueueModel.Config(blockMs: 100, inputRate: 48000, inputBufferFrames: 480,
                                     outputRate: 48000, outputBufferFrames: 480,
                                     blockOut: 4800, prefill: 100_000, maxFill: 7200)
        let r = QueueModel.run(processingMs: [20, 20], config: tiny)   // prefill beyond the whole stream
        XCTAssertEqual(r.underrunEvents, 0)
        let nan = QueueModel.run(processingMs: [.nan], config: config)
        XCTAssertEqual(nan.underrunEvents, 0)
        // a callback grid that never advances must bail out, not loop
        for phase in [Double.nan, -.infinity] {
            var c = config; c.callbackPhaseMs = phase
            XCTAssertEqual(QueueModel.run(processingMs: [20, 20], config: c).underrunEvents, 0)
        }
        for rate in [0.0, Double.nan] {
            var c = config; c.outputRate = rate
            XCTAssertEqual(QueueModel.run(processingMs: [20, 20], config: c).underrunEvents, 0)
        }
    }

    // MARK: - Queue-level controller (P0). target = blockOut + prefill holds the newest block's
    // first sample ~prefill ahead of the read head, so outputQueue ≈ prefill instead of ratcheting up.

    private func controlled(_ band: Int) -> QueueModel.Config {
        var c = config
        c.controller = QueueModel.Controller(target: config.blockOut + config.prefill, band: band)
        return c
    }

    private func steadyPipeline(_ r: QueueModel.Result) -> Double {
        let s = (400..<580).map { r.blocks[$0].pipelineMs }.filter { $0.isFinite }.sorted()
        return s.isEmpty ? .nan : s[s.count / 2]
    }

    func testControllerHoldsLevelAfterUnderrunWithoutGrowingUnderruns() {
        // RTF 0.36 (worker catches up after the stall → the baseline phase ratchets up).
        var times = [Double](repeating: 36, count: 600)
        times[100] += 500
        let base = QueueModel.run(processingMs: times, config: config)
        let ctl = QueueModel.run(processingMs: times, config: controlled(480))
        XCTAssertGreaterThan(base.underrunEvents, 0)
        // criterion: pipeline p50 <= prefill + block_total + 5 ms, underruns must not grow
        let prefillMs = Double(config.prefill) / config.outputRate * 1000
        XCTAssertLessThanOrEqual(steadyPipeline(ctl), prefillMs + 36 + 5)
        XCTAssertLessThanOrEqual(ctl.underrunEvents, base.underrunEvents)
        // the ratchet is removed: the held level is below the baseline's drifted level
        XCTAssertLessThan(steadyPipeline(ctl), steadyPipeline(base))
        XCTAssertGreaterThan(avgQueue(ctl, from: 40000, to: 58000), 0)
        XCTAssertLessThan(avgQueue(ctl, from: 40000, to: 58000), avgQueue(base, from: 40000, to: 58000))
    }

    func testControllerHysteresisDoesNotChangeTheHeldLevel() {
        var times = [Double](repeating: 36, count: 600)
        times[100] += 500
        let a = QueueModel.run(processingMs: times, config: controlled(0))
        let b = QueueModel.run(processingMs: times, config: controlled(960))
        // band trades trim frequency for headroom, not the steady level
        XCTAssertEqual(steadyPipeline(a), steadyPipeline(b), accuracy: 0.001)
        XCTAssertEqual(a.underrunEvents, b.underrunEvents)
        XCTAssertGreaterThanOrEqual(a.trimEvents, b.trimEvents)
    }

    func testControllerDoesNotTrimAtRealTime() {
        // RTF ≈ 1: no sustained catch-up, so the level never exceeds target and trim stays off.
        var times = [Double](repeating: 100, count: 600)
        for b in 0..<600 { times[b] += b % 2 == 0 ? 1 : -1 }
        times[100] += 500
        let base = QueueModel.run(processingMs: times, config: config)
        let ctl = QueueModel.run(processingMs: times, config: controlled(480))
        XCTAssertEqual(ctl.trimEvents, 0)
        XCTAssertEqual(ctl.underrunEvents, base.underrunEvents)   // only the stall itself
    }

    func testControllerReplacesMaxFillOnBurst() {
        // A catch-up burst: baseline caps at frames + maxFill, the controller pulls down to target.
        // queueTrace records the pre-trim peak, so compare the held plateau after the burst.
        var times = [Double](repeating: 10, count: 60)
        times[5] = 450
        let base = QueueModel.run(processingMs: times, config: config)
        let ctl = QueueModel.run(processingMs: times, config: controlled(0))
        XCTAssertGreaterThan(base.trimEvents, 0)
        XCTAssertGreaterThan(ctl.trimEvents, 0)
        XCTAssertLessThan(avgQueue(ctl, from: 3000, to: 5500), avgQueue(base, from: 3000, to: 5500))
    }

    func testControllerDisabledKeepsLegacyBehavior() {
        var times = [Double](repeating: 36, count: 600)
        times[100] += 500
        let legacy = QueueModel.run(processingMs: times, config: config)
        var explicit = config
        explicit.controller = nil
        let same = QueueModel.run(processingMs: times, config: explicit)
        XCTAssertEqual(legacy.trimEvents, same.trimEvents)
        XCTAssertEqual(legacy.underrunEvents, same.underrunEvents)
        XCTAssertEqual(steadyPipeline(legacy), steadyPipeline(same), accuracy: 0.001)
    }

    func testTailDrainsWhenPrefillExceedsOneBlock() {
        // prefill > blockOut: an underrun near the last block leaves a tail smaller than
        // prefill; it must still play out instead of waiting for a prefill that can never come.
        var c = config
        c.prefill = 6000   // > blockOut 4800, <= 3 * blockOut
        let times = [20.0, 20, 2000]
        for ctl in [nil, QueueModel.Controller(target: c.blockOut + c.prefill, band: 480)] {
            c.controller = ctl
            let r = QueueModel.run(processingMs: times, config: c)
            XCTAssertGreaterThan(r.underrunEvents, 0)
            XCTAssertTrue(r.blocks[2].pipelineMs.isFinite)
        }
    }

    // MARK: - Replay of a recorded session (live A, 116.8 s) and the calibration gate.
    // The synthetic grid ran with +-1 ms jitter; the live trace has p99-p50 = 15.7 ms.

    private func liveAReplay() -> QueueModel.Replay {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/live-A-b50-replay.csv")
        let lines = try! String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var t: [Double] = [], p: [Double] = []
        for l in lines where !l.hasPrefix("#") && !l.hasPrefix("block") {
            let f = l.split(separator: ",").map { Double($0)! }
            t.append(f[1]); p.append(f[2])
        }
        return QueueModel.Replay(processingMs: p, finishedMs: t)
    }

    /// Session A geometry: b50, in/out 44.1 kHz, blockOut 2205, prefill blockOut/2, maxFill 1.5 blockOut.
    /// The output buffer was not logged in that session; 512 is what every device present reports.
    private func liveAConfig(phase: Double = 0) -> QueueModel.Config {
        QueueModel.Config(blockMs: 50, inputRate: 44100, inputBufferFrames: 512, outputRate: 44100, outputBufferFrames: 512,
                          blockOut: 2205, prefill: 1102, maxFill: 3307, callbackPhaseMs: phase)
    }

    private func liveACalibration() -> QueueModel.Calibration {
        // report live-20261117-115229: queue = p50(pipeline - block_total) = 60.3 ms, 22 trims, 19 underruns
        QueueModel.Calibration(queueP50Ms: 60.3, trims: 22, underruns: 19)
    }

    func testReplayOfLiveAIsNotCalibratedOnQueueLevel() {
        let r = QueueModel.replay(liveAReplay(), config: liveAConfig())
        let v = liveACalibration().evaluate(r)
        for m in v.metrics { print(String(format: "CALIBRATION %@: live %.1f model %.1f deviation %.1f%%%@",
                                           m.name, m.live, m.model, m.deviation * 100, m.withinTolerance ? "" : "  <- FAIL")) }
        print("REPLAY live A: trimFrames \(r.trimFrames) (live 6214), underrunFrames \(r.underrunFrames) (live 3924)")
        // the counts land within the gate, the level does not: the live queue sits well above what
        // the model's rules produce from the same block times (the output buffer of that session
        // was not logged; see testReplayDependsOnOutputBufferSize). Until that is understood the
        // replay is not a valid stand-in for the engine, and no controller is evaluated on it.
        XCTAssertEqual(r.trimEvents, 24)
        XCTAssertEqual(r.trimFrames, 6880)
        XCTAssertEqual(r.underrunEvents, 25)
        XCTAssertEqual(r.underrunFrames, 4078)
        XCTAssertEqual(v.failed, ["queueP50Ms", "underruns"])
        XCTAssertFalse(v.calibrated)
        XCTAssertGreaterThan(v.metrics[0].deviation, 0.20)
        XCTAssertTrue(v.metrics[1].withinTolerance)
    }

    func testReplayDependsOnOutputBufferSize() {
        // The same block times, only the output buffer changed. The held level moves with it by
        // tens of ms, so a replay of a session whose buffer was not logged cannot be trusted.
        var levels: [Double] = []
        for frames in [64, 256, 512, 1024, 2048] {
            var c = liveAConfig()
            c.outputBufferFrames = frames
            let r = QueueModel.replay(liveAReplay(), config: c)
            let level = Distribution.of(r.blocks.map(\.outputQueueMs)).p50
            levels.append(level)
            print(String(format: "REPLAY out buffer %4d: underruns %d/%d, trims %d/%d, queue p50 %.1f ms",
                         frames, r.underrunEvents, r.underrunFrames, r.trimEvents, r.trimFrames, level))
        }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertGreaterThan(levels.last! - levels.first!, 40)
    }

    func testReplayIsSensitiveToCallbackPhase() {
        // The callback grid's phase against the block writes is unknown in a recording. The verdict
        // must not hinge on it: sweep one buffer and require every phase to miss the same way.
        let cal = liveACalibration()
        var levels: [Double] = [], trims: [Int] = [], underruns: [Int] = []
        for i in 0..<12 {
            let r = QueueModel.replay(liveAReplay(), config: liveAConfig(phase: Double(i) * 11.61 / 12))
            XCTAssertEqual(r.blocks.count, 2328)
            levels.append(Distribution.of(r.blocks.map(\.outputQueueMs)).p50)
            trims.append(r.trimEvents); underruns.append(r.underrunEvents)
            XCTAssertFalse(cal.evaluate(r).calibrated, "phase \(i)")
        }
        print("REPLAY phase sweep: queue p50 \(levels.min()!)...\(levels.max()!) ms, trims \(trims.min()!)...\(trims.max()!), underruns \(underruns.min()!)...\(underruns.max()!)")
        XCTAssertLessThan(levels.max()!, 60.3 * 0.8)   // never near the live level
    }

    func testCalibrationGateRule() {
        var times = [Double](repeating: 36, count: 800)
        for b in stride(from: 100, to: 700, by: 50) { times[b] += 500 }   // twelve stalls
        let r = QueueModel.run(processingMs: times, config: config)
        let underruns = r.underrunEvents, trims = r.trimEvents
        XCTAssertEqual(underruns, 12)                                     // one per stall
        XCTAssertGreaterThan(trims, 0)
        let queue = Distribution.of(r.blocks.map(\.outputQueueMs)).p50
        let exact = QueueModel.Calibration(queueP50Ms: queue, trims: trims, underruns: underruns).evaluate(r)
        XCTAssertTrue(exact.calibrated)
        XCTAssertTrue(exact.metrics.allSatisfy { $0.deviation == 0 })
        // inclusive at the tolerance, failing just past it. The deviation is relative to the live
        // value: 12 modelled against 10 live is exactly 20%, against 9 it is 33%.
        let at = QueueModel.Calibration(queueP50Ms: queue, trims: trims, underruns: 10).evaluate(r)
        XCTAssertTrue(at.calibrated)
        let past = QueueModel.Calibration(queueP50Ms: queue, trims: trims, underruns: 9).evaluate(r)
        XCTAssertFalse(past.calibrated)
        XCTAssertEqual(past.failed, ["underruns"])
        // a live count of zero only matches a model count of zero (no relative deviation is defined)
        let clean = QueueModel.run(processingMs: [20, 20, 20], config: config)
        XCTAssertEqual(clean.trimEvents, 0)
        let zeroQueue = Distribution.of(clean.blocks.map(\.outputQueueMs)).p50
        XCTAssertTrue(QueueModel.Calibration(queueP50Ms: zeroQueue, trims: 0, underruns: 0).evaluate(clean).calibrated)
        XCTAssertFalse(QueueModel.Calibration(queueP50Ms: queue, trims: 0, underruns: underruns).evaluate(r).calibrated)
        // no resolved block: nothing to calibrate against, even with zeros on both sides
        let empty = QueueModel.run(processingMs: [], config: config)
        XCTAssertEqual(empty.trimEvents, 0)
        XCTAssertFalse(QueueModel.Calibration(queueP50Ms: 0, trims: 0, underruns: 0).evaluate(empty).calibrated)
    }
}
