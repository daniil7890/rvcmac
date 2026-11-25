import Foundation

/// Virtual-time model of the live queues, driven by measured block times.
/// It applies the same rules as the engine (prefill, output queue limit, trim in the output callback),
/// but its results are calculated, not measured: real end-to-end latency only comes from a live session.
public enum QueueModel {
    /// Active queue-level control: hold the queue near `target` instead of letting its phase
    /// ratchet up after underruns. When the level exceeds target + band, trim down to target;
    /// the next trim fires only after the level climbs the band again (hysteresis).
    /// Replaces the maxFill rule while enabled, including the first callback after a re-prefill,
    /// so a catch-up overshoot is trimmed immediately instead of becoming the new phase.
    /// At RTF ≈ 1 there is no sustained catch-up, the level never reaches target + band and trim
    /// stays off (for the recommended target); the controller only regulates when the worker runs ahead (RTF < 1).
    public struct Controller: Sendable {
        /// Post-trim queue level in frames. Recommended `blockOut + prefill`: the newest block's
        /// first sample then sits ~prefill ahead of the read head (outputQueue ≈ prefill). Must stay
        /// above `blockOut + outputBufferFrames`, or the queue drains below one buffer between writes.
        public var target: Int
        public var band: Int     // hysteresis above target, frames
        public init(target: Int, band: Int) {
            precondition(target > 0 && band >= 0, "Controller target must be positive and band non-negative")
            self.target = target; self.band = band
        }
    }

    public struct Config: Sendable {
        public var blockMs: Double
        public var inputRate: Double
        public var inputBufferFrames: Int
        public var outputRate: Double
        public var outputBufferFrames: Int
        public var blockOut: Int
        public var prefill: Int
        public var maxFill: Int
        public var controller: Controller?
        /// Phase of the output callback grid relative to the first block, ms. The synthetic path
        /// starts at 0; a replay is sensitive to it, so `replay` can sweep it over one buffer.
        public var callbackPhaseMs: Double

        public init(blockMs: Double, inputRate: Double, inputBufferFrames: Int, outputRate: Double, outputBufferFrames: Int,
                    blockOut: Int, prefill: Int, maxFill: Int, controller: Controller? = nil, callbackPhaseMs: Double = 0) {
            self.blockMs = blockMs; self.inputRate = inputRate; self.inputBufferFrames = inputBufferFrames
            self.outputRate = outputRate; self.outputBufferFrames = outputBufferFrames
            self.blockOut = blockOut; self.prefill = prefill; self.maxFill = maxFill
            self.controller = controller; self.callbackPhaseMs = callbackPhaseMs
        }
    }

    /// A recorded session, replayed through the model instead of a synthetic block grid.
    /// `finishedMs` is when block i became readable for the output (the live row's t_sec: it is
    /// appended right after the block is written), `processingMs` its block_total. The block's
    /// last input sample is taken as finished - processing; the live capture timestamp also
    /// contains the worker's poll delay and write overhead (about 0..1.5 ms), so the replay
    /// reads the pipeline slightly low.
    public struct Replay: Sendable {
        public var processingMs: [Double]
        public var finishedMs: [Double]
        public init(processingMs: [Double], finishedMs: [Double]) {
            precondition(processingMs.count == finishedMs.count, "Replay needs one finish time per block")
            self.processingMs = processingMs; self.finishedMs = finishedMs
        }
    }

    public struct Block: Sendable {
        public var inputWaitMs: Double    // block available -> worker starts it
        public var outputQueueMs: Double  // block written -> its first sample plays (NaN if trimmed or never played)
        public var pipelineMs: Double     // capture of the last sample -> playback of the first output sample (NaN likewise)
    }

    public struct QueueSample: Sendable {
        public var tMs: Double
        public var queueMs: Double
    }

    public struct Result: Sendable {
        public var blocks: [Block]
        /// End-of-stream drain (all blocks written) is excluded from the underrun counters.
        public var underrunEvents = 0
        public var underrunFrames = 0
        public var trimEvents = 0
        public var trimFrames = 0
        /// Queue level at every output callback, including the silent prefill waits.
        public var queueTrace: [QueueSample] = []
    }

    public static func run(processingMs: [Double], config c: Config) -> Result {
        let n = processingMs.count
        var capture = [Double](repeating: 0, count: n)
        var finished = [Double](repeating: 0, count: n)

        // Worker: a block can start once the input callback holding its last sample has run.
        let inBufMs = Double(c.inputBufferFrames) / c.inputRate * 1000
        var previousEnd = 0.0
        var inputWait = [Double](repeating: 0, count: n)
        for b in 0..<n {
            capture[b] = Double(b + 1) * c.blockMs
            let available = (capture[b] / inBufMs).rounded(.up) * inBufMs
            let start = max(available, previousEnd)
            inputWait[b] = start - available
            previousEnd = start + processingMs[b]
            finished[b] = previousEnd
        }
        return simulate(processingMs: processingMs, capture: capture, finished: finished, inputWait: inputWait, config: c)
    }

    /// Replays recorded block times through the same output rules (prefill, trim, underrun).
    /// Results are only as good as the calibration gate: check `Calibration.evaluate` first.
    public static func replay(_ r: Replay, config c: Config) -> Result {
        let n = r.processingMs.count
        var capture = [Double](repeating: 0, count: n)
        for b in 0..<n { capture[b] = r.finishedMs[b] - r.processingMs[b] }
        return simulate(processingMs: r.processingMs, capture: capture, finished: r.finishedMs,
                        inputWait: [Double](repeating: .nan, count: n), config: c)
    }

    private static func simulate(processingMs: [Double], capture: [Double], finished: [Double],
                                 inputWait: [Double], config c: Config) -> Result {
        let n = processingMs.count
        var blocks = [Block](repeating: Block(inputWaitMs: 0, outputQueueMs: .nan, pipelineMs: .nan), count: n)
        for b in 0..<n { blocks[b].inputWaitMs = inputWait[b] }

        var result = Result(blocks: [])
        guard n > 0, c.blockOut > 0, c.outputBufferFrames > 0 else { result.blocks = blocks; return result }
        // degenerate configs would never start playback or never advance: bail out instead of looping forever
        // (a non-finite callback phase or rate would keep `now` from ever reaching a finish time)
        guard c.prefill <= n * c.blockOut, c.outputRate.isFinite, c.outputRate > 0, c.callbackPhaseMs.isFinite,
              processingMs.allSatisfy({ $0.isFinite }),
              capture.allSatisfy({ $0.isFinite }), finished.allSatisfy({ $0.isFinite }),
              zip(finished, finished.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else { result.blocks = blocks; return result }

        // Output callbacks, one per device buffer.
        let frames = c.outputBufferFrames
        let bufMs = Double(frames) / c.outputRate * 1000
        var read = 0
        var written = 0     // blocks fully written so far
        var resolved = 0    // blocks already played or given up on
        var started = false
        let totalFrames = n * c.blockOut
        var k = 0
        while read < totalFrames {
            let now = c.callbackPhaseMs + Double(k) * bufMs
            k += 1
            while written < n && finished[written] <= now { written += 1 }
            let writePos = written * c.blockOut
            result.queueTrace.append(QueueSample(tMs: now, queueMs: Double(writePos - read) / c.outputRate * 1000))
            // at end of stream play out the tail even if it can never reach prefill again
            // (prefill > blockOut and an underrun near the last block would otherwise loop forever)
            if !started && (writePos - read >= c.prefill || (written == n && writePos - read > 0)) { started = true }
            guard started else { continue }
            if written == n && writePos - read <= 0 { break }

            let queued = writePos - read
            if let ctl = c.controller {
                // hold the level near target: trim the overshoot above target + band down to
                // target. Fires on the first started callback after a re-prefill too, so catch-up
                // cannot set a new, higher phase. The clamp to one device buffer only prevents an
                // immediate over-read; a target below blockOut + frames still underruns between writes.
                let floor = max(ctl.target, frames)
                if queued - floor > ctl.band {
                    let skip = queued - floor
                    read += skip
                    result.trimEvents += 1
                    result.trimFrames += skip
                    resolved = max(resolved, written)
                }
            } else if queued > frames && queued - frames > c.maxFill {
                let skip = queued - frames - c.maxFill
                read += skip
                result.trimEvents += 1
                result.trimFrames += skip
                // the engine forgets every block waiting to play: its timing is unknown after a trim
                resolved = max(resolved, written)
            }
            let got = min(frames, writePos - read)
            while resolved < written {
                let w0 = resolved * c.blockOut
                guard w0 < read + got else { break }
                let play = now + Double(w0 - read) / c.outputRate * 1000
                blocks[resolved].outputQueueMs = play - finished[resolved]
                blocks[resolved].pipelineMs = play - capture[resolved]
                resolved += 1
            }
            read += got
            if got < frames && written < n {
                result.underrunEvents += 1
                result.underrunFrames += frames - got
                // A2: the callback ramps down and waits for a new prefill before resuming
                started = false
            }
        }
        result.blocks = blocks
        return result
    }

    /// Calibration gate for a replay: before any controller result from a replay is used, the
    /// model must reproduce the recorded session's queue level, trim count and underrun count,
    /// each within `tolerance` (relative). A miss on any one means "not calibrated": the replay
    /// disagrees with the live engine on something that decides the queue, so a controller
    /// evaluated on it would be evaluated on the wrong system.
    public struct Calibration: Sendable {
        public var queueP50Ms: Double     // live: p50 of (pipeline − block_total) over resolved blocks
        public var trims: Int
        public var underruns: Int
        public var tolerance: Double

        public init(queueP50Ms: Double, trims: Int, underruns: Int, tolerance: Double = 0.20) {
            self.queueP50Ms = queueP50Ms; self.trims = trims; self.underruns = underruns; self.tolerance = tolerance
        }

        public struct Metric: Sendable {
            public var name: String
            public var live: Double
            public var model: Double
            /// |model − live| / live
            public var deviation: Double
            public var withinTolerance: Bool
        }

        public struct Verdict: Sendable {
            public var metrics: [Metric]
            public var calibrated: Bool
            public var failed: [String] { metrics.filter { !$0.withinTolerance }.map(\.name) }
        }

        public func evaluate(_ r: Result) -> Verdict {
            func metric(_ name: String, _ live: Double, _ model: Double) -> Metric {
                let d = live > 0 ? abs(model - live) / live : (model == live ? 0 : .infinity)
                return Metric(name: name, live: live, model: model, deviation: d, withinTolerance: d <= tolerance)
            }
            // no resolved block (everything trimmed, empty run): there is no level to compare
            let level = Distribution.of(r.blocks.map(\.outputQueueMs))
            let queue = level.count == 0
                ? Metric(name: "queueP50Ms", live: queueP50Ms, model: .nan, deviation: .infinity, withinTolerance: false)
                : metric("queueP50Ms", queueP50Ms, level.p50)
            let m = [queue,
                     metric("trims", Double(trims), Double(r.trimEvents)),
                     metric("underruns", Double(underruns), Double(r.underrunEvents))]
            return Verdict(metrics: m, calibrated: m.allSatisfy(\.withinTolerance))
        }
    }
}
