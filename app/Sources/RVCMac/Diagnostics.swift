import AVFoundation
import CoreML
import Darwin
import Foundation
import RVCMacCore

// MARK: - System and resource probes

enum SystemProbe {
    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    static func thermalName(_ s: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func info(thermalStart: String) -> Report.SystemInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Report.SystemInfo(macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                                 machine: sysctlString("hw.model"),
                                 chip: sysctlString("machdep.cpu.brand_string"),
                                 memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                                 thermalStart: thermalStart, thermalEnd: thermalName(),
                                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Physical footprint of this process (what Activity Monitor shows as "Memory").
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// User + system CPU time of this process, seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// Public APIs give no reliable per-process GPU / Neural Engine load, so reports say so instead of guessing.
    static let gpuAneNote = "нет публичного API для нагрузки GPU/ANE процесса; смотри Instruments → Core ML / Metal System Trace"
}

/// Samples CPU %, memory and thermal state about once a second.
final class ResourceMonitor {
    struct Sample {
        var cpuPercent: Double
        var memoryMB: Double
        var thermal: String
    }

    private var lastCPU = SystemProbe.cpuSeconds()
    private var lastWall = Date()
    private(set) var samples: [Sample] = []

    func reset() {
        samples.removeAll()
        lastCPU = SystemProbe.cpuSeconds()
        lastWall = Date()
    }

    @discardableResult
    func sample() -> Sample {
        let cpu = SystemProbe.cpuSeconds()
        let now = Date()
        let dt = now.timeIntervalSince(lastWall)
        let pct = dt > 0 ? (cpu - lastCPU) / dt * 100 : 0
        lastCPU = cpu
        lastWall = now
        let s = Sample(cpuPercent: pct, memoryMB: SystemProbe.memoryMB(), thermal: SystemProbe.thermalName())
        samples.append(s)
        if samples.count > 7200 { samples.removeFirst(samples.count - 7200) }
        return s
    }

    var summary: Report.Resources {
        var thermal: [String: Int] = [:]
        for s in samples { thermal[s.thermal, default: 0] += 1 }
        return Report.Resources(cpuPercent: Distribution.of(samples.map(\.cpuPercent)),
                                memoryMB: Distribution.of(samples.map(\.memoryMB)),
                                thermalStates: thermal, gpuAne: SystemProbe.gpuAneNote)
    }
}

// MARK: - Reports on disk

enum ReportStore {
    static var directory: URL { RVCMacPaths.home.appendingPathComponent("reports") }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// Writes `<base>.json` and `<base>.csv` (+ `<base>.wav` when audio is given). Returns the JSON URL.
    @discardableResult
    static func save(_ report: Report, rows: [BlockRow], audio: [Float]? = nil, sampleRate: Double = 48000) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(report.kind == .live ? "live" : "bench")-\(stamp(report.createdAt))-\(safe(report.model.name))-b\(report.config.blockMs)"
        let json = directory.appendingPathComponent(base + ".json")
        try ReportMath.encoder().encode(report).write(to: json, options: .atomic)
        try ReportMath.csv(rows).write(to: directory.appendingPathComponent(base + ".csv"), atomically: true, encoding: .utf8)
        if let audio, !audio.isEmpty {
            try writeWAV(audio, rate: sampleRate, to: directory.appendingPathComponent(base + ".wav"))
        }
        return json
    }

    static func list() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func load(_ url: URL) throws -> Report {
        try ReportMath.decoder().decode(Report.self, from: Data(contentsOf: url))
    }

    static func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }
}

// MARK: - File benchmark

struct BenchmarkOptions {
    var sourceURL: URL?
    var runs = 3
    var warmupBlocks = 10
    /// Feed blocks at real-time intervals (like the live engine) instead of back to back.
    var realtimePacing = true
    var saveOutput = true
    var outputRate = 48000.0
    var maxSeconds = 120.0
}

struct BenchmarkResult {
    var report: Report
    var rows: [BlockRow]
    var output: [Float]
}

enum BenchmarkError: LocalizedError {
    case tooShort, cancelled
    var errorDescription: String? {
        switch self {
        case .tooShort: return "Аудиофайл слишком короткий для этого размера блока"
        case .cancelled: return "Бенчмарк остановлен"
        }
    }
}

enum BenchmarkRunner {
    /// Mono 16 kHz audio from any file AVAudioFile can read (wav, aiff, m4a, mp3, caf...).
    static func loadAudio16k(_ url: URL, maxSeconds: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let frames = AVAudioFrameCount(min(Double(f.length), maxSeconds * fmt.sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return [] }
        try f.read(into: buf, frameCount: frames)
        let ch = Int(fmt.channelCount), n = Int(buf.frameLength)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch {
            let p = buf.floatChannelData![c]
            for i in 0..<n { mono[i] += p[i] / Float(ch) }
        }
        return Resampler(from: fmt.sampleRate, to: 16000).stream(mono)
    }

    /// Deterministic voice-like test signal: harmonic tone with gliding pitch, vibrato and pauses.
    /// Good for timing; use a real recording to judge sound quality.
    static func syntheticVoice(seconds: Double = 20) -> [Float] {
        let sr = 16000.0
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        var noise = Gaussian()
        for i in 0..<n {
            let t = Double(i) / sr
            let inPhrase = t.truncatingRemainder(dividingBy: 2.0)
            let env: Double = inPhrase < 1.5 ? sin(Double.pi * inPhrase / 1.5) : 0
            let f0 = 110 + 110 * (0.5 + 0.5 * sin(2 * Double.pi * t / 7)) + 4 * sin(2 * Double.pi * 5.5 * t)
            phase += f0 / sr
            var v = 0.0
            for k in 1...20 { v += sin(2 * Double.pi * phase * Double(k)) / Double(k) }
            out[i] = Float(0.12 * env * v) + 0.002 * noise.next()
        }
        return out
    }

    static func run(voice: VoiceInfo, config cfg: LatencyConfig, compute: ComputeChoice, params: EngineParams,
                    options: BenchmarkOptions, progress: (String) -> Void, isCancelled: () -> Bool) throws -> BenchmarkResult {
        let thermalStart = SystemProbe.thermalName()
        let monitor = ResourceMonitor()
        monitor.reset()

        progress("Загрузка моделей…")
        var t0 = HostTime.now()
        let loaded = try LoadedVoice(voice: voice, config: cfg, units: compute.units)
        let loadMs = HostTime.ms(from: t0, to: HostTime.now())
        let pipeline = try VoicePipeline(model: loaded, outRate: options.outputRate)

        let audio = try options.sourceURL.map { try loadAudio16k($0, maxSeconds: options.maxSeconds) } ?? syntheticVoice()
        let block16 = pipeline.block16
        let nBlocks = audio.count / block16
        guard nBlocks >= 4 else { throw BenchmarkError.tooShort }

        var p = params
        p.gateDB = -200   // every block goes through the models
        p.bypass = false
        var times = StageTimes()

        progress("Холодный старт: первый блок…")
        t0 = HostTime.now()
        _ = try audio.withUnsafeBufferPointer { a in
            try pipeline.process(UnsafeBufferPointer(start: a.baseAddress!, count: block16), params: p, times: &times)
        }
        let firstBlockMs = HostTime.ms(from: t0, to: HostTime.now())

        progress("Прогрев…")
        for i in 0..<options.warmupBlocks {
            if isCancelled() { throw BenchmarkError.cancelled }
            _ = try audio.withUnsafeBufferPointer { a in
                try pipeline.process(UnsafeBufferPointer(start: a.baseAddress! + (i % nBlocks) * block16, count: block16), params: p, times: &times)
            }
        }

        let recorder = BlockRecorder(capacity: options.runs * nBlocks + 1)
        var output: [Float] = []
        var runs: [Report.RunSummary] = []
        let blockSec = Double(cfg.blockMs) / 1000
        var lastSample = Date()
        for r in 1...options.runs {
            pipeline.reset()
            let runStart = HostTime.now()
            var totalMs = 0.0
            for b in 0..<nBlocks {
                if isCancelled() { throw BenchmarkError.cancelled }
                if options.realtimePacing {
                    let wait = Double(b) * blockSec * 1000 - HostTime.ms(from: runStart, to: HostTime.now())
                    if wait > 0 { usleep(useconds_t(wait * 1000)) }
                }
                times.reset()
                let res = try audio.withUnsafeBufferPointer { a in
                    try pipeline.process(UnsafeBufferPointer(start: a.baseAddress! + b * block16, count: block16), params: p, times: &times)
                }
                totalMs += times[.total]
                let alg = LatencyMath.algorithmicMs(blockF: cfg.blockF, solaF: cfg.solaF, crossfadeF: cfg.crossfadeF,
                                                    solaOffset: pipeline.lastOffset, outputRate: options.outputRate)
                let id = recorder.append(run: r, t: Double(b) * blockSec, flags: res.flags, stages: times, algorithmicMs: alg, solaOffset: pipeline.lastOffset)
                // offline: "pipeline" is the processing time; no devices or queues
                recorder.setLatency(id: id, pipelineMs: times[.total], endToEndMs: times[.total] + alg)
                if r == 1 && options.saveOutput {
                    output.append(contentsOf: pipeline.out[0..<pipeline.outCount])
                }
                if Date().timeIntervalSince(lastSample) >= 1 {
                    monitor.sample()
                    lastSample = Date()
                }
                if b % 20 == 0 { progress("Прогон \(r)/\(options.runs): блок \(b)/\(nBlocks)") }
            }
            let wall = HostTime.ms(from: runStart, to: HostTime.now()) / 1000
            let runRows = recorder.rows().filter { $0.run == r }
            let audioSec = Double(nBlocks) * blockSec
            runs.append(Report.RunSummary(index: r, blocks: nBlocks, inferredBlocks: runRows.filter { $0.flags.inferred }.count,
                                          wallSeconds: wall, audioSeconds: audioSec,
                                          realTimeFactor: totalMs / 1000 / audioSec,
                                          stages: ReportMath.stageDistributions(runRows)))
        }
        monitor.sample()

        let rows = recorder.rows()
        var counters = Report.Counters()
        counters.blocks = rows.count
        counters.inferredBlocks = rows.filter { $0.flags.inferred }.count
        var config = Report.ConfigInfo(compute: compute.rawValue, blockMs: cfg.blockMs, extraMs: cfg.extraMs, crossfadeMs: cfg.crossfadeMs,
                                       inputRate: 16000, outputRate: options.outputRate, pitch: params.pitch,
                                       indexRatio: Double(params.indexRatio), protect: Double(params.protect), gateDB: Double(p.gateDB))
        config.sourceFile = options.sourceURL?.lastPathComponent ?? "synthetic-voice-20s"
        config.realtimePacing = options.realtimePacing
        config.warmupBlocks = options.warmupBlocks
        let report = Report(kind: .file, createdAt: Date(), appVersion: SystemProbe.appVersion,
                            system: SystemProbe.info(thermalStart: thermalStart),
                            model: Report.ModelInfo(name: voice.name, version: voice.version, sampleRate: voice.sr, indexVectors: voice.index?.count),
                            config: config,
                            coldStart: Report.ColdStart(loadMs: loadMs, firstBlockMs: firstBlockMs),
                            stages: ReportMath.stageDistributions(rows),
                            latency: ReportMath.latency(rows, deviceInputMs: 0, deviceOutputMs: 0),
                            runs: runs, counters: counters, resources: monitor.summary,
                            notes: [
                                "Файловый тест: задержка = алгоритмическая + обработка, без устройств и очередей.",
                                "Порог тишины отключён, чтобы каждый блок проходил через модели.",
                                "Загрузка моделей включает компиляцию .mlmodelc только если кэш устарел; кэш Neural Engine у macOS свой.",
                            ])
        return BenchmarkResult(report: report, rows: rows, output: output)
    }
}
