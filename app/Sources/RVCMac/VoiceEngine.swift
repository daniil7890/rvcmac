import CoreAudio
import CoreML
import Foundation
import os
import RVCMacCore

/// What the UI shows while running. Distributions cover a recent window (last 64 blocks).
struct EngineStats {
    var processMs: Double = 0           // slowest block in the last report period
    var blockMs: Double = 0
    var inputDB: Float = -120
    var gated = false
    var stageP50 = [Double](repeating: 0, count: Stage.allCases.count)
    var stageP95 = [Double](repeating: 0, count: Stage.allCases.count)
    var pipeline = Distribution.empty
    var endToEnd = Distribution.empty
    var algorithmicMs: Double = 0
    var deviceInputMs: Double = 0
    var deviceOutputMs: Double = 0
    var outputQueueMs: Double = 0
    var counters = Report.Counters()
    var overloads = 0
    var inputBufferFrames = 0
    var outputBufferFrames = 0
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
final class VoiceEngine {
    let io = AudioIO()
    private let modelLock = OSAllocatedUnfairLock()
    private var activeModel: LoadedVoice
    private var thread: Thread?
    private var threadActive = false
    private let finished = DispatchSemaphore(value: 0)
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let paramsLock = OSAllocatedUnfairLock(initialState: EngineParams())
    private let swapLock = OSAllocatedUnfairLock(uncheckedState: (ModelState, UInt64)?.none)

    private let recorderLock = OSAllocatedUnfairLock()
    private let recorder = BlockRecorder(capacity: 40_000)   // ~100 min at 150 ms blocks
    private let outputOverflow = AtomicInt(0)
    private let skipped16 = AtomicInt(0)
    private let modelSwitches = AtomicInt(0)
    private(set) var sessionStarted = Date()

    /// Worker thread callbacks; the receiver hops to the main actor itself.
    var onStats: ((EngineStats) -> Void)?
    var onError: ((String) -> Void)?
    var onModelSwitched: ((String, Double) -> Void)?

    init(model: LoadedVoice) {
        activeModel = model
    }

    var params: EngineParams {
        get { paramsLock.withLock { $0 } }
        set { paramsLock.withLock { $0 = newValue } }
    }

    var muted: Bool {
        get { io.muted.value != 0 }
        set { io.muted.value = newValue ? 1 : 0 }
    }

    var currentModel: LoadedVoice { modelLock.withLockUnchecked { activeModel } }

    private var isRunning: Bool { running.withLock { $0 } }

    private var prepared: VoicePipeline?

    /// Builds the pipeline and runs a few inferences on silence before audio starts (call off the main thread).
    /// Without this the first, slow (cold Neural Engine) blocks let input pile up; the backlog then sits in the
    /// output queue as permanent extra latency. Returns the warm-up time in ms.
    @discardableResult
    func prepare(outputRate: Double, blocks: Int = 3) throws -> Double {
        let t0 = HostTime.now()
        let pipeline = try VoicePipeline(model: currentModel, outRate: outputRate)
        var p = params
        p.gateDB = -200
        p.bypass = false
        var times = StageTimes()
        let silence = [Float](repeating: 0, count: pipeline.block16)
        for _ in 0..<blocks {
            _ = try silence.withUnsafeBufferPointer { try pipeline.process($0, params: p, times: &times) }
        }
        pipeline.reset()
        prepared = pipeline
        return HostTime.ms(from: t0, to: HostTime.now())
    }

    func start(input: AudioDeviceID, output: AudioDeviceID) throws {
        stop()
        try io.start(input: input, output: output)
        let pipeline: VoicePipeline
        do {
            if let p = prepared, p.outRate == io.outputRate, p.state.model === currentModel {
                pipeline = p
            } else {
                pipeline = try VoicePipeline(model: currentModel, outRate: io.outputRate)
            }
            prepared = nil
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
        for c in [outputOverflow, skipped16, modelSwitches] { c.value = 0 }
        sessionStarted = Date()
        running.withLock { $0 = true }
        let inRate = io.inputRate, outRate = io.outputRate
        let t = Thread { [weak self] in
            guard let self else { return }
            self.loop(pipeline: pipeline, inRate: inRate, outRate: outRate)
        }
        t.qualityOfService = .userInteractive
        t.name = "RVCMac.inference"
        thread = t
        threadActive = true
        t.start()
    }

    func stop() {
        running.withLock { $0 = false }
        if threadActive {
            // the worker finishes its current block (at most one inference) and exits
            if finished.wait(timeout: .now() + 3) == .timedOut {
                onError?(tr("Поток обработки не завершился за 3 с"))
            }
            threadActive = false
        }
        thread = nil
        io.stop()
    }

    /// Prepares the new voice off the worker thread (call from a background task), then hands it over.
    /// The active voice keeps playing until the worker switches at the next block boundary.
    func switchModel(to model: LoadedVoice) throws {
        guard model.config.key == currentModel.config.key else {
            throw NSError(domain: "RVCMac", code: 20, userInfo: [NSLocalizedDescriptionKey: tr("Переключение на лету требует одинаковых настроек задержки")])
        }
        let state = try ModelState(model: model, outRate: io.outputRate)
        swapLock.withLockUnchecked { $0 = (state, HostTime.now()) }
    }

    // MARK: - Session data

    func sessionRows() -> [BlockRow] { recorderLock.withLockUnchecked { recorder.rows() } }

    func counters(rows: [BlockRow]) -> Report.Counters {
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
        return c
    }

    // MARK: - Worker loop

    private struct Pending {
        var w0: UInt64
        var captureNs: Double
        var algorithmicMs: Double
        var id: Int
    }

    private func loop(pipeline: VoicePipeline, inRate: Double, outRate: Double) {
        defer { finished.signal() }
        let chunk = 4096
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { tmp.deallocate() }
        let inRes = Resampler(from: inRate, to: 16000)
        let tmp16Cap = inRes.maxOutput(for: chunk)
        let tmp16 = UnsafeMutablePointer<Float>.allocate(capacity: tmp16Cap)
        defer { tmp16.deallocate() }
        let block16 = pipeline.block16
        let accCap = max(block16 * 6, tmp16Cap * 2)
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: accCap)
        defer { acc.deallocate() }
        var accCount = 0
        var abs16 = 0.0  // cumulative 16 kHz index of acc[0]

        func dropFront(_ n: Int) {
            let n = min(n, accCount)
            guard n > 0 else { return }
            memmove(acc, acc + n, (accCount - n) * MemoryLayout<Float>.size)
            accCount -= n
            abs16 += Double(n)
        }

        let cfg = pipeline.cfg
        let deviceMs = io.inputLatencyMs + io.outputLatencyMs
        var times = StageTimes()
        var inputResampleMs = 0.0
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
                recorderLock.withLockUnchecked { recorder.setLatency(id: e.id, pipelineMs: pipelineMs, endToEndMs: e2e) }
                recentPipeline.add(pipelineMs)
                recentE2E.add(e2e)
                resolved += 1
            }
            if resolved > 0 { pending.removeFirst(resolved) }
            if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        }

        while isRunning {
            let n = io.inputRing.read(into: tmp, count: chunk)
            if n > 0 {
                let t0 = HostTime.now()
                let m = inRes.stream(UnsafeBufferPointer(start: tmp, count: n), into: tmp16, capacity: tmp16Cap)
                inputResampleMs += HostTime.ms(from: t0, to: HostTime.now())
                if accCount + m > accCap {
                    let drop = accCount + m - accCap
                    skipped16.add(min(drop, accCount))
                    dropFront(drop)
                }
                (acc + accCount).update(from: tmp16, count: m)
                accCount += m
            }
            resolvePending()

            guard accCount >= block16 else {
                usleep(1000)
                continue
            }
            // if we fell far behind, skip old audio instead of growing latency forever
            if accCount > block16 * 4 {
                let drop = accCount - block16 * 2
                skipped16.add(drop)
                dropFront(drop)
            }
            let swap = swapLock.withLockUnchecked { (s: inout (ModelState, UInt64)?) -> (ModelState, UInt64)? in
                let v = s
                s = nil
                return v
            }
            if let swap {
                pipeline.replaceModel(swap.0)
                modelLock.withLockUnchecked { activeModel = swap.0.model }
                switchRequestedAt = swap.1
            }

            times.reset()
            times[.inputResample] = inputResampleMs
            inputResampleMs = 0
            let p = params
            let result: (db: Float, flags: BlockFlags)
            do {
                result = try pipeline.process(UnsafeBufferPointer(start: acc, count: block16), params: p, times: &times)
            } catch {
                onError?(trf("Ошибка инференса: %@", "\(error.localizedDescription)"))
                running.withLock { $0 = false }
                break
            }
            let blockEnd16 = abs16 + Double(block16)
            dropFront(block16)

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
            let id = recorderLock.withLockUnchecked {
                recorder.append(run: 0, t: tSec, flags: result.flags, stages: times, algorithmicMs: algorithmic, solaOffset: pipeline.lastOffset)
            }
            if captureNs.isFinite && written == count {
                pending.append(Pending(w0: w0, captureNs: captureNs, algorithmicMs: algorithmic, id: id))
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
                var c = Report.Counters()
                c.blocks = recorderLock.withLockUnchecked { recorder.total }
                c.underrunEvents = io.underrunEvents.value
                c.underrunFrames = io.underrunFrames.value
                c.inputOverflowFrames = io.inputRing.dropped
                c.skippedInputMs = Double(skipped16.value) / 16
                c.outputTrimFrames = io.trimFrames.value
                c.outputOverflowFrames = outputOverflow.value
                c.modelSwitches = modelSwitches.value
                stats.counters = c
                stats.overloads = io.overloads.value
                lastReport = HostTime.now()
                onStats?(stats)
            }
        }
    }
}
