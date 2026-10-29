import Foundation

/// Pipeline stages timed for every block.
public enum Stage: Int, CaseIterable, Codable, Sendable {
    case inputResample   // device rate -> 16 kHz (accumulated since the previous block)
    case embedder        // ContentVec
    case pitch           // FCPE + f0 decoding
    case features        // index retrieval, x2 upscale, protect
    case excitation      // coarse pitch, NSF sine, prior noise
    case synth           // RVC synthesizer
    case output          // resample to the output rate + SOLA
    case total           // whole block on the worker thread (excluding input resample)

    public var key: String {
        switch self {
        case .inputResample: return "input_resample"
        case .embedder: return "contentvec"
        case .pitch: return "pitch_fcpe"
        case .features: return "features_index"
        case .excitation: return "excitation"
        case .synth: return "synth_rvc"
        case .output: return "output_sola"
        case .total: return "block_total"
        }
    }

    public var title: String {
        switch self {
        case .inputResample: return tr("Ресемплинг входа")
        case .embedder: return "ContentVec"
        case .pitch: return tr("Тон (FCPE)")
        case .features: return tr("Признаки / index")
        case .excitation: return tr("Возбуждение (NSF)")
        case .synth: return tr("Синтезатор RVC")
        case .output: return tr("Ресемплинг + SOLA")
        case .total: return tr("Блок целиком")
        }
    }
}

/// Stage durations of one block in milliseconds. Reused in place, so filling it never allocates.
public struct StageTimes: Sendable {
    public var ms: [Double]
    public init() { ms = [Double](repeating: 0, count: Stage.allCases.count) }
    public subscript(_ s: Stage) -> Double {
        get { ms[s.rawValue] }
        set { ms[s.rawValue] = newValue }
    }
    public mutating func reset() {
        for i in 0..<ms.count { ms[i] = 0 }
    }
}

public struct BlockFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let gated = BlockFlags(rawValue: 1)        // below the silence gate: no inference
    public static let bypass = BlockFlags(rawValue: 2)       // processing bypassed
    public static let modelSwitch = BlockFlags(rawValue: 4)  // first block after a model switch
    public static let warmup = BlockFlags(rawValue: 8)

    /// Only these blocks ran the models, so only they count for stage timings.
    public var inferred: Bool { !contains(.gated) && !contains(.bypass) }
}

/// One recorded block.
public struct BlockRow: Sendable {
    public var run: Int
    public var index: Int
    public var t: Double            // seconds since the session/run started
    public var flags: BlockFlags
    public var stages: [Double]     // indexed by Stage.rawValue
    public var pipelineMs: Double   // capture of the block's last sample -> playback of its first output sample (NaN if unknown)
    public var endToEndMs: Double   // pipeline + algorithmic + device latency (NaN if unknown)
    public var algorithmicMs: Double
    public var solaOffset: Int
}

/// Fixed-capacity block log: storage is allocated once, appending never allocates.
/// Not thread-safe; the owner guards it.
public final class BlockRecorder {
    private static let stageCount = Stage.allCases.count
    // per-block fields: run, index, t, flags, stages..., pipeline, e2e, algorithmic, offset
    private static let fields = 4 + stageCount + 4
    private var storage: [Double]
    public let capacity: Int
    /// Total blocks appended (can exceed capacity: the oldest are then overwritten).
    public private(set) var total = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [Double](repeating: 0, count: self.capacity * Self.fields)
    }

    public func reset() { total = 0 }

    /// Returns an id usable with `setLatency` while the block is still stored.
    @discardableResult
    public func append(run: Int, t: Double, flags: BlockFlags, stages: StageTimes, algorithmicMs: Double, solaOffset: Int) -> Int {
        let id = total
        let base = (id % capacity) * Self.fields
        storage[base] = Double(run)
        storage[base + 1] = Double(id)
        storage[base + 2] = t
        storage[base + 3] = Double(flags.rawValue)
        for s in 0..<Self.stageCount { storage[base + 4 + s] = stages.ms[s] }
        let tail = base + 4 + Self.stageCount
        storage[tail] = .nan
        storage[tail + 1] = .nan
        storage[tail + 2] = algorithmicMs
        storage[tail + 3] = Double(solaOffset)
        total += 1
        return id
    }

    public func setLatency(id: Int, pipelineMs: Double, endToEndMs: Double) {
        guard id >= 0, id < total, id >= total - capacity else { return }
        let tail = (id % capacity) * Self.fields + 4 + Self.stageCount
        storage[tail] = pipelineMs
        storage[tail + 1] = endToEndMs
    }

    public var storedCount: Int { min(total, capacity) }

    /// Oldest-first copy of the stored blocks. `last` limits it to the newest n.
    public func rows(last: Int? = nil) -> [BlockRow] {
        let n = min(storedCount, last ?? Int.max)
        var out: [BlockRow] = []
        out.reserveCapacity(n)
        for id in (total - n)..<total {
            let base = (id % capacity) * Self.fields
            let tail = base + 4 + Self.stageCount
            out.append(BlockRow(run: Int(storage[base]), index: Int(storage[base + 1]), t: storage[base + 2],
                                flags: BlockFlags(rawValue: Int(storage[base + 3])),
                                stages: Array(storage[(base + 4)..<(base + 4 + Self.stageCount)]),
                                pipelineMs: storage[tail], endToEndMs: storage[tail + 1],
                                algorithmicMs: storage[tail + 2], solaOffset: Int(storage[tail + 3])))
        }
        return out
    }
}

/// Latency arithmetic shared by the engine, the benchmark and the tests.
public enum LatencyMath {
    /// Algorithmic delay of one output block: the decoded region ends at the window end and is
    /// `blockF + solaF + crossfadeF` frames of 10 ms long; the block is taken from its start plus the
    /// SOLA offset, so an output sample lags its input by that region minus the offset.
    public static func algorithmicMs(blockF: Int, solaF: Int, crossfadeF: Int, solaOffset: Int, outputRate: Double) -> Double {
        let region = Double(blockF + solaF + crossfadeF) * 10
        return region - Double(solaOffset) / outputRate * 1000
    }

    /// Host time (ns) of a sample position, extrapolated from an anchor (position, host time) of the same stream.
    public static func hostNs(of position: Double, anchorPosition: Double, anchorNs: Double, rate: Double) -> Double {
        anchorNs + (position - anchorPosition) / rate * 1e9
    }

    /// Position in the device input stream that corresponds to a cumulative 16 kHz sample index.
    public static func inputPosition(from16k index16: Double, inputRate: Double) -> Double {
        index16 * inputRate / 16000
    }
}
