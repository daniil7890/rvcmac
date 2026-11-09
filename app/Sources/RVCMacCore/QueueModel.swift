import Foundation

/// Virtual-time model of the live queues, driven by measured block times.
/// It applies the same rules as the engine (prefill, output queue limit, trim in the output callback),
/// but its results are calculated, not measured: real end-to-end latency only comes from a live session.
public enum QueueModel {
    public struct Config: Sendable {
        public var blockMs: Double
        public var inputRate: Double
        public var inputBufferFrames: Int
        public var outputRate: Double
        public var outputBufferFrames: Int
        public var blockOut: Int
        public var prefill: Int
        public var maxFill: Int

        public init(blockMs: Double, inputRate: Double, inputBufferFrames: Int, outputRate: Double, outputBufferFrames: Int,
                    blockOut: Int, prefill: Int, maxFill: Int) {
            self.blockMs = blockMs; self.inputRate = inputRate; self.inputBufferFrames = inputBufferFrames
            self.outputRate = outputRate; self.outputBufferFrames = outputBufferFrames
            self.blockOut = blockOut; self.prefill = prefill; self.maxFill = maxFill
        }
    }

    public struct Block: Sendable {
        public var inputWaitMs: Double    // block available -> worker starts it
        public var outputQueueMs: Double  // block written -> its first sample plays (NaN if trimmed or never played)
        public var pipelineMs: Double     // capture of the last sample -> playback of the first output sample (NaN likewise)
    }

    public struct Result: Sendable {
        public var blocks: [Block]
        public var underrunEvents = 0
        public var underrunFrames = 0
        public var trimEvents = 0
        public var trimFrames = 0
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
            if !started && writePos - read >= c.prefill { started = true }
            guard started else { continue }
            if written == n && writePos - read <= 0 { break }

            let queued = writePos - read
            if queued > frames && queued - frames > c.maxFill {
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
            }
        }
        result.blocks = blocks
        return result
    }
}
