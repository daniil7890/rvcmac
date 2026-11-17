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

        public init(blockMs: Double, inputRate: Double, inputBufferFrames: Int, outputRate: Double, outputBufferFrames: Int,
                    blockOut: Int, prefill: Int, maxFill: Int, controller: Controller? = nil) {
            self.blockMs = blockMs; self.inputRate = inputRate; self.inputBufferFrames = inputBufferFrames
            self.outputRate = outputRate; self.outputBufferFrames = outputBufferFrames
            self.blockOut = blockOut; self.prefill = prefill; self.maxFill = maxFill
            self.controller = controller
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
        var blocks = [Block](repeating: Block(inputWaitMs: 0, outputQueueMs: .nan, pipelineMs: .nan), count: n)

        // Worker: a block can start once the input callback holding its last sample has run.
        let inBufMs = Double(c.inputBufferFrames) / c.inputRate * 1000
        var previousEnd = 0.0
        for b in 0..<n {
            capture[b] = Double(b + 1) * c.blockMs
            let available = (capture[b] / inBufMs).rounded(.up) * inBufMs
            let start = max(available, previousEnd)
            blocks[b].inputWaitMs = start - available
            previousEnd = start + processingMs[b]
            finished[b] = previousEnd
        }

        var result = Result(blocks: [])
        guard n > 0, c.blockOut > 0, c.outputBufferFrames > 0 else { result.blocks = blocks; return result }
        // degenerate configs would never start playback or never advance: bail out instead of looping forever
        guard c.prefill <= n * c.blockOut, processingMs.allSatisfy({ $0.isFinite }) else { result.blocks = blocks; return result }

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
            let now = Double(k) * bufMs
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
}
