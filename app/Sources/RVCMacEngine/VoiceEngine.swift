import CoreAudio
import CoreML
import Foundation
import os
import RVCMacCore

/// What the UI shows while running. Distributions cover a recent window (last 64 blocks).
package struct EngineStats {
    package var processMs: Double = 0           // slowest block in the last report period
    package var blockMs: Double = 0
    package var inputDB: Float = -120
    package var gated = false
    package var stageP50 = [Double](repeating: 0, count: Stage.allCases.count)
    package var stageP95 = [Double](repeating: 0, count: Stage.allCases.count)
    package var pipeline = Distribution.empty
    package var endToEnd = Distribution.empty
    package var algorithmicMs: Double = 0
    package var deviceInputMs: Double = 0
    package var deviceOutputMs: Double = 0
    package var outputQueueMs: Double = 0
    package var counters = Report.Counters()
    package var overloads = 0
    package var inputBufferFrames = 0
    package var outputBufferFrames = 0
    package init() {}
}

/// Fixed-size ring of recent values for cheap rolling percentiles on the worker thread.
private struct RecentWindow {
    private var values: [Double]
    private var next = 0
    private(set) var count = 0
    init(size: Int) { values = [Double](repeating: 0, count: size) }
    mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        values[next] = v
        next = (next + 1) % values.count
        count = min(count + 1, values.count)
    }
    var distribution: Distribution { Distribution.of(values[0..<count]) }
}

/// Live engine: Core Audio I/O + a worker thread that runs `VoicePipeline` block by block and measures it.
package final class VoiceEngine {
    package let io = AudioIO()
    private let modelLock = OSAllocatedUnfairLock()
    private var activeModel: LoadedVoice
    private var thread: Thread?
    private let session = WorkerSession()
    private let releaser = ModelReleaser(label: "RVCMac.modelRelease")
    private let paramsLock = OSAllocatedUnfairLock(initialState: EngineParams())
    private let swapLock = OSAllocatedUnfairLock(uncheckedState: (ModelState, UInt64)?.none)

    private let recorderLock = OSAllocatedUnfairLock()
    private let recorder = BlockRecorder(capacity: 40_000)   // ~100 min at 150 ms blocks
    private let outputOverflow = AtomicInt(0)
    private let skipped16 = AtomicInt(0)
    private let modelSwitches = AtomicInt(0)
    private let droppedRows = AtomicInt(0)
    package private(set) var sessionStarted = Date()

    /// Worker thread callbacks; the receiver hops to the main actor itself.
    package var onStats: ((EngineStats) -> Void)?
    package var onError: ((String) -> Void)?
    package var onModelSwitched: ((String, Double) -> Void)?

    package init(model: LoadedVoice) {
        activeModel = model
    }

    deinit {
        // the engine can be released on any thread; keep model deallocation off it (B5)
        releaser.release(activeModel)
        if let prepared { releaser.release(prepared) }
        let pending = swapLock.withLockUnchecked { s -> ModelState? in
            let old = s?.0
            s = nil
            return old
        }
        if let pending { releaser.release(pending) }
    }

    package var params: EngineParams {
        get { paramsLock.withLock { $0 } }
        set { paramsLock.withLock { $0 = newValue } }
    }

    package var muted: Bool {
        get { io.muted.value != 0 }
        set { io.muted.value = newValue ? 1 : 0 }
    }

    package var currentModel: LoadedVoice { modelLock.withLockUnchecked { activeModel } }

    private var prepared: VoicePipeline?

    /// Builds the pipeline and runs a few inferences on silence before audio starts (call off the main thread).
    /// Without this the first, slow (cold Neural Engine) blocks let input pile up; the backlog then sits in the
    /// output queue as permanent extra latency. Returns the warm-up time in ms.
    @discardableResult
    package func prepare(outputRate: Double, blocks: Int = 3) throws -> Double {
        let t0 = HostTime.now()
        let pipeline = try VoicePipeline(model: currentModel, outRate: outputRate)
        var p = params
        p.gateDB = -200
        p.bypass = false
        var times = StageTimes()
        let silence = [Float](repeating: 0, count: pipeline.block16)
        do {
            for _ in 0..<blocks {
                _ = try silence.withUnsafeBufferPointer { try pipeline.process($0, params: p, times: &times) }
            }
        } catch {
            releaser.release(pipeline)   // a failed warm-up must not deinit models on the caller (B5)
            throw error
        }
        pipeline.reset()
        let old = prepared
        prepared = pipeline
        if let old { releaser.release(old) }
        return HostTime.ms(from: t0, to: HostTime.now())
    }

    package func start(input: AudioDeviceID, output: AudioDeviceID) throws {
        stop()
        try io.start(input: input, output: output)
        let pipeline: VoicePipeline
        do {
            if let p = prepared, p.outRate == io.outputRate, p.state.model === currentModel {
                pipeline = p
            } else {
                pipeline = try VoicePipeline(model: currentModel, outRate: io.outputRate)
            }
            let old = prepared
            prepared = nil
            // a mismatched warm-up pipeline must not deinit its models on main (B5)
            if let old, old !== pipeline { releaser.release(old) }
        } catch {
            io.stop()
            throw error
        }
        io.outputPrefill.value = pipeline.blockOut / 2
        // Right after a block is written the queue holds that block plus the leftover of the previous ones.
        // Capping it at 1.5 blocks keeps up to half a block of leftover as margin for processing jitter,
        // while a standing backlog (start-up, a slow block) is dropped once instead of adding latency for
        // the rest of the session (was 3 blocks). Trims are counted in the diagnostics.
        io.outputMaxFill.value = pipeline.blockOut + pipeline.blockOut / 2
        recorderLock.withLockUnchecked { recorder.reset() }
        for c in [outputOverflow, skipped16, modelSwitches, droppedRows] { c.value = 0 }
        sessionStarted = Date()
        let worker = session.begin()
        let inRate = io.inputRate, outRate = io.outputRate
        let t = Thread { [weak self, releaser] in
            // a session that never runs must still signal, or stop() would wait forever
            guard let self else { releaser.release(pipeline); worker.done.signal(); return }
            self.loop(pipeline: pipeline, inRate: inRate, outRate: outRate, token: worker.token, done: worker.done)
        }
        t.qualityOfService = .userInteractive
        t.name = "RVCMac.inference"
        thread = t
        t.start()
    }

    package func stop() {
        session.end()
        // the worker finishes its current block (at most one inference) and exits;
        // a slow exit is reported, but stop() still joins the worker (C2)
        session.join { onError?(tr("Поток обработки не завершился за 3 с")) }
        thread = nil
        io.stop()
    }

    /// Prepares the new voice off the worker thread (call from a background task), then hands it over.
    /// The active voice keeps playing until the worker switches at the next block boundary.
    package func switchModel(to model: LoadedVoice) throws {
        guard model.config.key == currentModel.config.key else {
            throw NSError(domain: "RVCMac", code: 20, userInfo: [NSLocalizedDescriptionKey: tr("Переключение на лету требует одинаковых настроек задержки")])
        }
        let state = try ModelState(model: model, outRate: io.outputRate)
        let overwritten = swapLock.withLockUnchecked { s -> ModelState? in
            let old = s?.0
            s = (state, HostTime.now())
            return old
        }
        if let overwritten { releaser.release(overwritten) }   // never deallocate under the lock (B5)
    }

    // MARK: - Session data

    package func sessionRows() -> [BlockRow] {
        // one flat copy under the lock; rows are materialized outside it so the worker
        // never waits for an export (B4)
        let snapshot = recorderLock.withLockUnchecked { recorder.snapshot() }
        return snapshot.rows()
    }

    package func counters(rows: [BlockRow]) -> Report.Counters {
        var c = Report.Counters()
        c.blocks = rows.count
        c.inferredBlocks = rows.filter { $0.flags.inferred }.count
        c.gatedBlocks = rows.filter { $0.flags.contains(.gated) }.count
        c.underrunEvents = io.underrunEvents.value
        c.underrunFrames = io.underrunFrames.value
        c.inputOverflowFrames = io.inputRing.dropped
        c.skippedInputMs = Double(skipped16.value) / 16
        c.outputTrimFrames = io.trimFrames.value
        c.outputOverflowFrames = outputOverflow.value
        c.modelSwitches = modelSwitches.value
        c.droppedRows = droppedRows.value
        return c
    }

    // MARK: - Worker loop

    private struct Pending {
        var w0: UInt64
        var captureNs: Double
        var algorithmicMs: Double
        var id: Int
    }

    private func loop(pipeline: VoicePipeline, inRate: Double, outRate: Double, token: UInt64, done: DispatchSemaphore) {
        defer {
            // release the pipeline off the worker before signaling: the closure's captures
            // are freed after the signal, so join() alone would not cover them (B5)
            releaser.release(pipeline)
            done.signal()
        }
        let block16 = pipeline.block16
        let input = InputAssembler(inputRate: inRate, block16: block16, skipped: skipped16)

        let cfg = pipeline.cfg
        let deviceMs = io.inputLatencyMs + io.outputLatencyMs
        var times = StageTimes()
        var pending: [Pending] = []
        pending.reserveCapacity(80)
        var lastTrimEvents = io.trimEvents.value
        var recentStages = (0..<Stage.allCases.count).map { _ in RecentWindow(size: 64) }
        var recentPipeline = RecentWindow(size: 64)
        var recentE2E = RecentWindow(size: 64)
        var periodMax = 0.0
        var stats = EngineStats()
        stats.blockMs = Double(cfg.blockMs)
        stats.deviceInputMs = io.inputLatencyMs
        stats.deviceOutputMs = io.outputLatencyMs
        stats.inputBufferFrames = io.inputBufferFrames
        stats.outputBufferFrames = io.outputBufferFrames
        var lastReport = HostTime.now()
        var lastTotal = 0
        let startHost = HostTime.now()
        var switchRequestedAt: UInt64?

        func resolvePending() {
            let trims = io.trimEvents.value
            if trims != lastTrimEvents {
                // trimmed samples were never played, so their timing is unknown
                pending.removeAll(keepingCapacity: true)
                lastTrimEvents = trims
            }
            guard !pending.isEmpty, let a = io.outputClock.read() else { return }
            let anchorNs = HostTime.ns(a.hostTime)
            var resolved = 0
            for e in pending {
                guard a.position >= e.w0 else { break }
                let playNs = LatencyMath.hostNs(of: Double(e.w0), anchorPosition: Double(a.position), anchorNs: anchorNs, rate: outRate)
                let pipelineMs = (playNs - e.captureNs) / 1e6
                let e2e = pipelineMs + e.algorithmicMs + deviceMs
                // never wait for an exporter holding the lock; a skipped update is counted (B4)
                if recorderLock.withLockIfAvailable({ recorder.setLatency(id: e.id, pipelineMs: pipelineMs, endToEndMs: e2e) }) == nil {
                    droppedRows.add(1)
                }
                recentPipeline.add(pipelineMs)
                recentE2E.add(e2e)
                resolved += 1
            }
            if resolved > 0 { pending.removeFirst(resolved) }
            if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        }

        while session.isCurrent(token) {
            input.pull(from: io.inputRing)
            resolvePending()

            guard input.count >= block16 else {
                usleep(1000)
                continue
            }
            let swap = swapLock.withLockUnchecked { (s: inout (ModelState, UInt64)?) -> (ModelState, UInt64)? in
                let v = s
                s = nil
                return v
            }
            if let swap {
                // hand the old models to the background: deallocation must not run on the
                // worker or under modelLock (B5)
                let oldState = pipeline.state
                pipeline.replaceModel(swap.0)
                let oldModel = modelLock.withLockUnchecked { () -> LoadedVoice in
                    let old = activeModel
                    activeModel = swap.0.model
                    return old
                }
                releaser.release(oldState, oldModel)
                switchRequestedAt = swap.1
            }

            times.reset()
            times[.inputResample] = input.takeResampleMs()
            let p = params
            let result: (db: Float, flags: BlockFlags)
            do {
                result = try pipeline.process(input.block, params: p, times: &times)
            } catch {
                onError?(trf("Ошибка инференса: %@", "\(error.localizedDescription)"))
                session.end(token: token)
                break
            }
            let blockEnd16 = input.consumeBlock()

            let w0 = io.outputRing.writePosition
            let count = pipeline.outCount
            let written = pipeline.out.withUnsafeBufferPointer { io.outputRing.write($0.baseAddress!, count: count) }
            if written < count { outputOverflow.add(count - written) }

            // when was the block's last input sample captured?
            var captureNs = Double.nan
            if let a = io.inputClock.read() {
                let pos = LatencyMath.inputPosition(from16k: blockEnd16, inputRate: inRate) - 1
                captureNs = LatencyMath.hostNs(of: pos, anchorPosition: Double(a.position), anchorNs: HostTime.ns(a.hostTime), rate: inRate)
            }
            let algorithmic = result.flags.contains(.bypass)
                ? Double(cfg.blockMs)
                : LatencyMath.algorithmicMs(blockF: cfg.blockF, solaF: cfg.solaF, crossfadeF: cfg.crossfadeF,
                                            solaOffset: pipeline.lastOffset, outputRate: outRate)
            let tSec = HostTime.ms(from: startHost, to: HostTime.now()) / 1000
            let id = recorderLock.withLockIfAvailable {
                recorder.append(run: 0, t: tSec, flags: result.flags, stages: times, algorithmicMs: algorithmic, solaOffset: pipeline.lastOffset)
            }
            if let id {
                if captureNs.isFinite && written == count {
                    pending.append(Pending(w0: w0, captureNs: captureNs, algorithmicMs: algorithmic, id: id))
                }
            } else {
                droppedRows.add(1)   // the exporter holds the lock; skip the row, never wait (B4)
            }
            if let req = switchRequestedAt, result.flags.contains(.modelSwitch) {
                modelSwitches.add(1)
                let name = currentModel.voice.name
                onModelSwitched?(name, HostTime.ms(from: req, to: HostTime.now()))
                switchRequestedAt = nil
            }

            if result.flags.inferred {
                for s in Stage.allCases { recentStages[s.rawValue].add(times[s]) }
            }
            periodMax = max(periodMax, times[.total])
            stats.inputDB = result.db
            stats.gated = result.flags.contains(.gated)
            stats.algorithmicMs = algorithmic

            if HostTime.ms(from: lastReport, to: HostTime.now()) > 300 {
                stats.processMs = periodMax
                periodMax = 0
                for s in Stage.allCases {
                    let d = recentStages[s.rawValue].distribution
                    stats.stageP50[s.rawValue] = d.p50
                    stats.stageP95[s.rawValue] = d.p95
                }
                stats.pipeline = recentPipeline.distribution
                stats.endToEnd = recentE2E.distribution
                stats.outputQueueMs = Double(io.outputRing.available) / outRate * 1000
                if let total = recorderLock.withLockIfAvailable({ recorder.total }) { lastTotal = total }
                var c = Report.Counters()
                c.blocks = lastTotal
                c.underrunEvents = io.underrunEvents.value
                c.underrunFrames = io.underrunFrames.value
                c.inputOverflowFrames = io.inputRing.dropped
                c.skippedInputMs = Double(skipped16.value) / 16
                c.outputTrimFrames = io.trimFrames.value
                c.outputOverflowFrames = outputOverflow.value
                c.modelSwitches = modelSwitches.value
                c.droppedRows = droppedRows.value
                stats.counters = c
                stats.overloads = io.overloads.value
                lastReport = HostTime.now()
                onStats?(stats)
            }
        }
    }
}
