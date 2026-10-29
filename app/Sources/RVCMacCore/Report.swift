import Foundation

/// Everything a benchmark or a live session produced, saved as JSON next to a CSV of raw blocks.
public struct Report: Codable, Sendable {
    public var schema = 1
    public var kind: Kind
    public var createdAt: Date
    public var appVersion: String
    public var system: SystemInfo
    public var model: ModelInfo
    public var config: ConfigInfo
    public var coldStart: ColdStart?
    /// Stage timings over all inferred blocks (all runs).
    public var stages: [String: Distribution]
    public var latency: LatencySummary?
    public var runs: [RunSummary]
    public var counters: Counters
    public var resources: Resources?
    public var notes: [String]

    public enum Kind: String, Codable, Sendable {
        case file = "benchmark-file"
        case live
    }

    public struct SystemInfo: Codable, Sendable {
        public var macOS: String
        public var machine: String
        public var chip: String
        public var memoryGB: Double
        public var thermalStart: String
        public var thermalEnd: String
        public var lowPowerMode: Bool
        public init(macOS: String, machine: String, chip: String, memoryGB: Double, thermalStart: String, thermalEnd: String, lowPowerMode: Bool) {
            self.macOS = macOS; self.machine = machine; self.chip = chip; self.memoryGB = memoryGB
            self.thermalStart = thermalStart; self.thermalEnd = thermalEnd; self.lowPowerMode = lowPowerMode
        }
    }

    public struct ModelInfo: Codable, Sendable {
        public var name: String
        public var version: String
        public var sampleRate: Int
        public var indexVectors: Int?
        public init(name: String, version: String, sampleRate: Int, indexVectors: Int?) {
            self.name = name; self.version = version; self.sampleRate = sampleRate; self.indexVectors = indexVectors
        }
    }

    public struct ConfigInfo: Codable, Sendable {
        public var compute: String
        public var blockMs: Int
        public var extraMs: Int
        public var crossfadeMs: Int
        public var inputRate: Double
        public var outputRate: Double
        public var pitch: Int
        public var indexRatio: Double
        public var protect: Double
        public var gateDB: Double
        public var inputDevice: String?
        public var outputDevice: String?
        public var sourceFile: String?
        public var realtimePacing: Bool?
        public var warmupBlocks: Int?
        public init(compute: String, blockMs: Int, extraMs: Int, crossfadeMs: Int, inputRate: Double, outputRate: Double,
                    pitch: Int, indexRatio: Double, protect: Double, gateDB: Double) {
            self.compute = compute; self.blockMs = blockMs; self.extraMs = extraMs; self.crossfadeMs = crossfadeMs
            self.inputRate = inputRate; self.outputRate = outputRate; self.pitch = pitch
            self.indexRatio = indexRatio; self.protect = protect; self.gateDB = gateDB
        }

        /// Parameters that make two reports comparable (devices and file names excluded).
        public var comparableKey: String {
            "\(compute)|b\(blockMs)|e\(extraMs)|c\(crossfadeMs)|in\(Int(inputRate))|out\(Int(outputRate))|ir\(indexRatio)|pr\(protect)"
        }
    }

    public struct ColdStart: Codable, Sendable {
        public var loadMs: Double        // compile (if not cached) + load of all Core ML models
        public var firstBlockMs: Double  // first inference (includes lazy device-specific preparation)
        public init(loadMs: Double, firstBlockMs: Double) { self.loadMs = loadMs; self.firstBlockMs = firstBlockMs }
    }

    public struct LatencySummary: Codable, Sendable {
        public var pipeline: Distribution   // capture of a block's last sample -> playback of its first output sample
        public var algorithmic: Distribution
        public var deviceInputMs: Double    // Core Audio latency + safety offset (+ stream latency)
        public var deviceOutputMs: Double
        public var endToEnd: Distribution   // pipeline + algorithmic + devices
        public init(pipeline: Distribution, algorithmic: Distribution, deviceInputMs: Double, deviceOutputMs: Double, endToEnd: Distribution) {
            self.pipeline = pipeline; self.algorithmic = algorithmic
            self.deviceInputMs = deviceInputMs; self.deviceOutputMs = deviceOutputMs; self.endToEnd = endToEnd
        }
    }

    public struct RunSummary: Codable, Sendable {
        public var index: Int
        public var blocks: Int
        public var inferredBlocks: Int
        public var wallSeconds: Double
        public var audioSeconds: Double
        /// Processing time / audio time (below 1 = faster than real time).
        public var realTimeFactor: Double
        public var stages: [String: Distribution]
        public init(index: Int, blocks: Int, inferredBlocks: Int, wallSeconds: Double, audioSeconds: Double, realTimeFactor: Double, stages: [String: Distribution]) {
            self.index = index; self.blocks = blocks; self.inferredBlocks = inferredBlocks; self.wallSeconds = wallSeconds
            self.audioSeconds = audioSeconds; self.realTimeFactor = realTimeFactor; self.stages = stages
        }
    }

    public struct Counters: Codable, Sendable {
        public var blocks = 0
        public var inferredBlocks = 0
        public var gatedBlocks = 0
        public var underrunEvents = 0       // output callbacks that ran out of processed audio
        public var underrunFrames = 0
        public var inputOverflowFrames = 0  // input samples dropped because the worker fell behind
        public var skippedInputMs = 0.0     // audio the worker skipped to catch up
        public var outputTrimFrames = 0     // output samples dropped to keep the queue short
        public var outputOverflowFrames = 0
        public var modelSwitches = 0
        public var errors = 0
        public init() {}
    }

    public struct Resources: Codable, Sendable {
        public var cpuPercent: Distribution   // % of one core, whole process
        public var memoryMB: Distribution     // physical footprint
        public var thermalStates: [String: Int]
        public var gpuAne: String
        public init(cpuPercent: Distribution, memoryMB: Distribution, thermalStates: [String: Int], gpuAne: String) {
            self.cpuPercent = cpuPercent; self.memoryMB = memoryMB; self.thermalStates = thermalStates; self.gpuAne = gpuAne
        }
    }

    public init(kind: Kind, createdAt: Date, appVersion: String, system: SystemInfo, model: ModelInfo, config: ConfigInfo,
                coldStart: ColdStart?, stages: [String: Distribution], latency: LatencySummary?, runs: [RunSummary],
                counters: Counters, resources: Resources?, notes: [String]) {
        self.kind = kind; self.createdAt = createdAt; self.appVersion = appVersion; self.system = system
        self.model = model; self.config = config; self.coldStart = coldStart; self.stages = stages
        self.latency = latency; self.runs = runs; self.counters = counters; self.resources = resources; self.notes = notes
    }
}

// MARK: - Summaries from raw rows

public enum ReportMath {
    /// Stage distributions over the inferred, non-warmup blocks.
    public static func stageDistributions(_ rows: [BlockRow]) -> [String: Distribution] {
        let used = rows.filter { $0.flags.inferred && !$0.flags.contains(.warmup) }
        var out: [String: Distribution] = [:]
        for s in Stage.allCases {
            out[s.key] = Distribution.of(used.map { $0.stages[s.rawValue] })
        }
        return out
    }

    public static func latency(_ rows: [BlockRow], deviceInputMs: Double, deviceOutputMs: Double) -> Report.LatencySummary {
        let used = rows.filter { !$0.flags.contains(.warmup) }
        return Report.LatencySummary(pipeline: Distribution.of(used.map(\.pipelineMs)),
                                     algorithmic: Distribution.of(used.map(\.algorithmicMs)),
                                     deviceInputMs: deviceInputMs, deviceOutputMs: deviceOutputMs,
                                     endToEnd: Distribution.of(used.map(\.endToEndMs)))
    }

    public static func csv(_ rows: [BlockRow]) -> String {
        var s = "run,block,t_sec,gated,bypass,model_switch,warmup,"
        s += Stage.allCases.map { $0.key + "_ms" }.joined(separator: ",")
        s += ",pipeline_ms,algorithmic_ms,end_to_end_ms,sola_offset\n"
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.3f", v) : "" }
        for r in rows {
            let flags = [BlockFlags.gated, .bypass, .modelSwitch, .warmup].map { r.flags.contains($0) ? "1" : "0" }
            s += "\(r.run),\(r.index),\(f(r.t)),\(flags.joined(separator: ",")),"
            s += r.stages.map(f).joined(separator: ",")
            s += ",\(f(r.pipelineMs)),\(f(r.algorithmicMs)),\(f(r.endToEndMs)),\(r.solaOffset)\n"
        }
        return s
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}

// MARK: - Comparing two reports

public struct ComparisonRow: Identifiable, Sendable {
    public var id: String { metric }
    public var metric: String
    public var a: Double
    public var b: Double
    public var delta: Double { b - a }
    public var deltaPercent: Double { a != 0 ? (b - a) / a * 100 : 0 }
}

public enum ReportComparison {
    /// Differences in configuration that make the timing comparison unfair.
    public static func configDifferences(_ a: Report, _ b: Report) -> [String] {
        var d: [String] = []
        func cmp<T: Equatable>(_ name: String, _ x: T, _ y: T) { if x != y { d.append("\(name): \(x) → \(y)") } }
        cmp(tr("модель"), a.model.name, b.model.name)
        cmp(tr("вычисления"), a.config.compute, b.config.compute)
        cmp(tr("блок, мс"), a.config.blockMs, b.config.blockMs)
        cmp(tr("контекст, мс"), a.config.extraMs, b.config.extraMs)
        cmp(tr("кроссфейд, мс"), a.config.crossfadeMs, b.config.crossfadeMs)
        cmp(tr("частота выхода"), Int(a.config.outputRate), Int(b.config.outputRate))
        cmp("index", a.config.indexRatio, b.config.indexRatio)
        cmp(tr("тип отчёта"), a.kind.rawValue, b.kind.rawValue)
        cmp(tr("источник"), a.config.sourceFile ?? "-", b.config.sourceFile ?? "-")
        cmp("Mac", a.system.machine, b.system.machine)
        return d
    }

    public static func rows(_ a: Report, _ b: Report) -> [ComparisonRow] {
        var out: [ComparisonRow] = []
        for s in Stage.allCases {
            guard let da = a.stages[s.key], let db = b.stages[s.key], da.count > 0, db.count > 0 else { continue }
            out.append(ComparisonRow(metric: "\(s.title) p50", a: da.p50, b: db.p50))
            out.append(ComparisonRow(metric: "\(s.title) p95", a: da.p95, b: db.p95))
            if s == .total { out.append(ComparisonRow(metric: "\(s.title) p99", a: da.p99, b: db.p99)) }
        }
        if let la = a.latency, let lb = b.latency, la.endToEnd.count > 0, lb.endToEnd.count > 0 {
            out.append(ComparisonRow(metric: tr("Полная задержка p50"), a: la.endToEnd.p50, b: lb.endToEnd.p50))
            out.append(ComparisonRow(metric: tr("Полная задержка p95"), a: la.endToEnd.p95, b: lb.endToEnd.p95))
            out.append(ComparisonRow(metric: tr("Полная задержка p99"), a: la.endToEnd.p99, b: lb.endToEnd.p99))
        }
        if let ca = a.coldStart, let cb = b.coldStart {
            out.append(ComparisonRow(metric: tr("Загрузка моделей"), a: ca.loadMs, b: cb.loadMs))
            out.append(ComparisonRow(metric: tr("Первый блок"), a: ca.firstBlockMs, b: cb.firstBlockMs))
        }
        out.append(ComparisonRow(metric: tr("Underrun (события)"), a: Double(a.counters.underrunEvents), b: Double(b.counters.underrunEvents)))
        return out
    }
}
