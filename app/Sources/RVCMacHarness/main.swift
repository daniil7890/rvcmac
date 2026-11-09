import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RVCMacCore
import RVCMacEngine

// Offline harness: runs the live VoicePipeline on a file, block by block, with no audio device.
// See docs/AUDIT_030.md, section 11.

let usage = """
usage: rvcmac-harness (--input FILE | --synthetic SECONDS) --voice NAME --block MS --extra MS --crossfade MS [options]

  --compute ane-gpu|ane|gpu|cpu   compute units (default ane-gpu)
  --pitch N                       semitones (default 0)
  --index X                       index ratio (default 0.5)
  --protect X                     protect (default 0.33)
  --gate DB                       silence gate (default -60, as in the app)
  --gate-hysteresis DB            gate closes this far below --gate (default 6)
  --gate-hold MS                  gate hold time (default 200)
  --overload-extra-ms MS          simulate overload on a virtual clock: add MS to each block in the window (off by default)
  --overload-start S              overload window start, seconds (default 3)
  --overload-seconds S            overload window length, seconds (default 5)
  --device-rate HZ                simulated input device rate (default 48000)
  --output-rate HZ                output rate (default 48000)
  --input-buffer FRAMES           simulated input buffer (default 512)
  --output-buffer FRAMES          simulated output buffer (default 512)
  --runs N                        runs (default 3)
  --warmup N                      warm-up blocks (default 10)
  --pacing realtime|fast          feed blocks in real time or back to back (default realtime)
  --seed N                        noise seed (default 1)
  --loop-minutes M                loop the input for M minutes in one run, no WAV (long runs)
  --home DIR                      folder holding models/ (default: searched upward from the current folder)
  --out DIR                       output folder (default <home>/reports/harness/<stamp>-<voice>-b<block>)
"""

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct Options {
    var values: [String: String] = [:]
    static let known: Set<String> = [
        "input", "synthetic", "voice", "block", "extra", "crossfade", "compute", "pitch", "index", "protect", "gate", "gate-hysteresis", "gate-hold",
        "overload-start", "overload-seconds", "overload-extra-ms",
        "device-rate", "output-rate", "input-buffer", "output-buffer", "runs", "warmup", "pacing", "seed",
        "loop-minutes", "home", "out",
    ]

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            guard args[i].hasPrefix("--") else { throw HarnessError("unexpected argument: \(args[i])") }
            let key = String(args[i].dropFirst(2))
            guard Self.known.contains(key) else { throw HarnessError("unknown option: --\(key)") }
            guard i + 1 < args.count else { throw HarnessError("missing value for --\(key)") }
            values[key] = args[i + 1]
            i += 2
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func required(_ key: String) throws -> String {
        guard let v = values[key] else { throw HarnessError("--\(key) is required") }
        return v
    }

    func int(_ key: String, _ fallback: Int? = nil) throws -> Int {
        guard let s = values[key] else {
            if let fallback { return fallback }
            throw HarnessError("--\(key) is required")
        }
        guard let v = Int(s) else { throw HarnessError("--\(key): not an integer: \(s)") }
        return v
    }

    func double(_ key: String, _ fallback: Double) throws -> Double {
        guard let s = values[key] else { return fallback }
        guard let v = Double(s) else { throw HarnessError("--\(key): not a number: \(s)") }
        return v
    }
}

// MARK: - Metrics file

struct Determinism: Codable {
    var runs: Int
    var bitExact: Bool
    var maxAbsDifference: Float      // largest sample difference from run 1, over all runs
    var rmsDifferenceDB: Double      // worst run's RMS difference from run 1, dBFS
    var sha256: [String]             // per run, of the float32 output
}

struct MemorySummary: Codable {
    var rssStartMB: Double
    var rssEndMB: Double
    var rssPeakMB: Double
    var footprintPeakMB: Double
    var lifetimeMaxFootprintMB: Double?
    var rssSlopeMBPerBlock: Double       // least-squares fit over all recorded blocks
    var footprintSlopeMBPerBlock: Double
    var perRunRssSlopeMBPerBlock: [Double]
}

struct QueueSummary: Codable {
    var modelled = true
    var note = "Calculated from measured block times with the engine's queue rules; not a measurement of a real device."
    var inputBufferFrames: Int
    var outputBufferFrames: Int
    var prefillFrames: Int
    var maxFillFrames: Int
    var inputWaitMs: Distribution
    var outputQueueMs: Distribution
    var pipelineMs: Distribution
    var algorithmicMs: Distribution
    var endToEndWithoutDevicesMs: Distribution
    var underrunEvents: Int
    var underrunFrames: Int
    var trimEvents: Int
    var trimFrames: Int
}

struct HarnessMetrics: Codable {
    var harnessSchema = 1
    var commit: String
    var seed: UInt64
    var pacing: String
    var report: Report
    var processWallMs: Distribution     // whole process() call; block_total stops before the autorelease pool drains
    var memory: MemorySummary
    var queueModel: QueueSummary
    var determinism: Determinism?
}

// MARK: - Helpers

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func lifetimeMaxFootprintMB() -> Double? {
    var usage = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return rc == 0 ? Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576 : nil
}

/// Least-squares slope of `y` over its index.
func slope(_ y: ArraySlice<Double>) -> Double {
    let n = Double(y.count)
    guard n >= 2 else { return 0 }
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    for (i, v) in y.enumerated() {
        let x = Double(i)
        sx += x; sy += v; sxx += x * x; sxy += x * v
    }
    let d = n * sxx - sx * sx
    return d != 0 ? (n * sxy - sx * sy) / d : 0
}

func loadMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let f = try AVAudioFile(forReading: url)
    let fmt = f.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else {
        throw HarnessError("cannot allocate a buffer for \(url.lastPathComponent)")
    }
    try f.read(into: buf)
    let ch = Int(fmt.channelCount), n = Int(buf.frameLength)
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<ch {
        let p = buf.floatChannelData![c]
        for i in 0..<n { mono[i] += p[i] / Float(ch) }
    }
    return (mono, fmt.sampleRate)
}

func findHome() -> URL? {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("models/voices").path) { return dir }
        dir.deleteLastPathComponent()
    }
    return nil
}

func gitCommit(in dir: URL) -> String {
    func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let head = run(["rev-parse", "--short", "HEAD"])
    if head.isEmpty { return "unknown" }
    // models and venv are local symlinks, so only tracked changes count as dirty
    return run(["status", "--porcelain", "--untracked-files=no"]).isEmpty ? head : head + "-dirty"
}

func sha256Hex(_ x: ArraySlice<Float>) -> String {
    let digest = x.withUnsafeBytes { SHA256.hash(data: $0) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

// MARK: - Run

func runHarness(_ o: Options) throws {
    guard let home = try o.string("home").map({ URL(fileURLWithPath: $0) }) ?? findHome() else {
        throw HarnessError("no models/voices found above the current folder; pass --home")
    }
    RVCMacPaths.homeOverride = home

    let voiceName = try o.required("voice")
    let voices = ModelLibrary.voices()
    guard let voice = voices.first(where: { $0.name == voiceName }) else {
        throw HarnessError("voice '\(voiceName)' not found; available: \(voices.map(\.name).joined(separator: ", "))")
    }
    let key = LatencyConfig.key(block: try o.int("block"), extra: try o.int("extra"), crossfade: try o.int("crossfade"))
    guard let cfg = voice.configs.values.first(where: { $0.key == key }) else {
        throw HarnessError("voice '\(voiceName)' has no config \(key); available: \(voice.configs.keys.sorted().joined(separator: ", "))")
    }
    let computeNames: [String: ComputeChoice] = ["ane-gpu": .neuralEngine, "ane": .aneOnly, "gpu": .gpu, "cpu": .cpu]
    let computeArg = o.string("compute") ?? "ane-gpu"
    guard let compute = computeNames[computeArg] else { throw HarnessError("--compute: unknown value \(computeArg)") }
    let pacingArg = o.string("pacing") ?? "realtime"
    guard pacingArg == "realtime" || pacingArg == "fast" else { throw HarnessError("--pacing: unknown value \(pacingArg)") }
    let realtime = pacingArg == "realtime"

    var params = EngineParams()
    params.pitch = try o.int("pitch", 0)
    params.indexRatio = Float(try o.double("index", 0.5))
    params.protect = Float(try o.double("protect", 0.33))
    params.gateDB = Float(try o.double("gate", -60))
    params.gateHysteresisDB = Float(try o.double("gate-hysteresis", Double(params.gateHysteresisDB)))
    params.gateHoldMs = Int(try o.double("gate-hold", Double(params.gateHoldMs)))
    params.bypass = false

    let deviceRate = try o.double("device-rate", 48000)
    let outputRate = try o.double("output-rate", 48000)
    let inputBuffer = try o.int("input-buffer", 512)
    let outputBuffer = try o.int("output-buffer", 512)
    let warmup = try o.int("warmup", 10)
    let seed = UInt64(try o.int("seed", 1))
    let loopMinutes = try o.double("loop-minutes", 0)
    let runs = loopMinutes > 0 ? 1 : try o.int("runs", 3)
    guard runs >= 1 else { throw HarnessError("--runs must be at least 1") }
    guard inputBuffer > 0, outputBuffer > 0 else { throw HarnessError("buffer sizes must be positive") }

    // Input at the simulated device rate.
    let sourceName: String
    let device: [Float]
    if let path = o.string("input") {
        let url = URL(fileURLWithPath: path)
        let (samples, rate) = try loadMono(url)
        device = rate == deviceRate ? samples : Resampler(from: rate, to: deviceRate).stream(samples)
        sourceName = url.lastPathComponent
    } else if let s = o.string("synthetic"), let seconds = Double(s), seconds > 0 {
        device = Resampler(from: 16000, to: deviceRate).stream(BenchmarkRunner.syntheticVoice(seconds: seconds))
        sourceName = "synthetic-voice-\(s)s"
    } else {
        throw HarnessError("--input FILE or --synthetic SECONDS is required")
    }

    let outDir = o.string("out").map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent("reports/harness/\(ReportStore.stamp())-\(ReportStore.safe(voice.name))-b\(cfg.blockMs)")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let thermalStart = SystemProbe.thermalName()
    let monitor = ResourceMonitor()
    monitor.reset()
    let rssStart = residentMB()

    print("loading \(voice.name) \(key) on \(compute.rawValue)")
    var t0 = HostTime.now()
    let loaded = try LoadedVoice(voice: voice, config: cfg, units: compute.units)
    let loadMs = HostTime.ms(from: t0, to: HostTime.now())
    let pipeline = try VoicePipeline(model: loaded, outRate: outputRate)
    let block16 = pipeline.block16
    let blockSec = Double(cfg.blockMs) / 1000

    let sourceBlocks = Int(Double(device.count) * 16000 / deviceRate) / block16 - 1
    guard sourceBlocks >= 4 else { throw HarnessError("input is too short for this block size") }
    let nBlocks = loopMinutes > 0 ? Int(loopMinutes * 60 / blockSec) : sourceBlocks
    let keepAudio = loopMinutes <= 0

    // Everything the loop writes to is allocated here, so the harness itself does not grow during a run.
    let total = runs * nBlocks
    let recorder = BlockRecorder(capacity: total + 1)
    var rss = [Double](repeating: 0, count: total)
    var footprint = [Double](repeating: 0, count: total)
    var wall = [Double](repeating: 0, count: total)   // around the whole process() call, autorelease pool drain included
    let outCapacity = keepAudio ? nBlocks * pipeline.blockOut : 0
    var reference = [Float](repeating: 0, count: outCapacity)
    var current = [Float](repeating: 0, count: outCapacity)

    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: inputBuffer)
    defer { tmp.deallocate() }
    let inputRing = SampleRing(capacity: 192_000 * 2)
    let skipped16 = AtomicInt(0)
    let overloadExtraMs = try o.double("overload-extra-ms", 0)
    let overloadStartMs = try o.double("overload-start", 3) * 1000
    let overloadEndMs = overloadStartMs + (try o.double("overload-seconds", 5)) * 1000
    let overloaded = overloadExtraMs > 0
    var backlogMs = [Double](repeating: 0, count: overloaded ? total : 0)
    var virtualStartMs = [Double](repeating: 0, count: overloaded ? total : 0)

    var times = StageTimes()
    var devicePos = 0
    /// Next simulated input buffer, wrapping around the source.
    func nextDeviceBuffer() {
        for i in 0..<inputBuffer {
            tmp[i] = device[devicePos]
            devicePos += 1
            if devicePos == device.count { devicePos = 0 }
        }
    }

    // Cold start and warm-up, on the source audio.
    var warmParams = params
    warmParams.gateDB = -200    // silence must reach the models here
    let silence16 = [Float](repeating: 0, count: block16)
    t0 = HostTime.now()
    _ = try silence16.withUnsafeBufferPointer { try pipeline.process($0, params: warmParams, times: &times) }
    let firstBlockMs = HostTime.ms(from: t0, to: HostTime.now())
    for _ in 0..<warmup {
        _ = try silence16.withUnsafeBufferPointer { try pipeline.process($0, params: warmParams, times: &times) }
    }

    var summaries: [Report.RunSummary] = []
    var hashes: [String] = []
    var maxDiff: Float = 0
    var worstRmsDB = -Double.infinity
    var bitExact = true
    var nextSample = Date().addingTimeInterval(1)
    var recorded = 0

    for run in 1...runs {
        pipeline.resetForHarness(seed: seed)
        inputRing.reset()
        skipped16.value = 0
        let input = InputAssembler(inputRate: deviceRate, block16: block16, skipped: skipped16)
        let bufferMs = Double(inputBuffer) / deviceRate * 1000
        var clockMs = 0.0
        var nextBufferEndMs = bufferMs
        var b = 0
        var outPos = 0
        devicePos = 0
        let runStart = HostTime.now()
        var totalMs = 0.0
        while b < nBlocks {
            if overloaded {
                while nextBufferEndMs <= clockMs {
                    nextDeviceBuffer()
                    _ = inputRing.write(tmp, count: inputBuffer)
                    nextBufferEndMs += bufferMs
                }
            } else {
                nextDeviceBuffer()
                _ = inputRing.write(tmp, count: inputBuffer)
            }
            input.pull(from: inputRing)
            if overloaded && input.count < block16 && inputRing.available == 0 { clockMs = max(clockMs, nextBufferEndMs) }

            while input.count >= block16 && b < nBlocks {
                input.limitBacklog()
                if realtime && !overloaded {
                    let wait = Double(b) * blockSec * 1000 - HostTime.ms(from: runStart, to: HostTime.now())
                    if wait > 0 { usleep(useconds_t(wait * 1000)) }
                }
                times.reset()
                times[.inputResample] = input.takeResampleMs()
                if overloaded {
                    backlogMs[recorded] = Double(inputRing.available) / deviceRate * 1000 + Double(input.count) / 16
                    virtualStartMs[recorded] = clockMs
                }
                let wall0 = HostTime.now()
                let res = try pipeline.process(input.block, params: params, times: &times)
                wall[recorded] = HostTime.ms(from: wall0, to: HostTime.now())
                input.consumeBlock()
                totalMs += times[.total]

                let alg = LatencyMath.algorithmicMs(blockF: cfg.blockF, solaF: cfg.solaF, crossfadeF: cfg.crossfadeF,
                                                    solaOffset: pipeline.lastOffset, outputRate: outputRate)
                recorder.append(run: run, t: Double(b) * blockSec, flags: res.flags, stages: times,
                                algorithmicMs: alg, solaOffset: pipeline.lastOffset)
                rss[recorded] = residentMB()
                footprint[recorded] = SystemProbe.memoryMB()
                recorded += 1

                if keepAudio {
                    let count = min(pipeline.outCount, outCapacity - outPos)
                    pipeline.out.withUnsafeBufferPointer { src in
                        current.withUnsafeMutableBufferPointer { ($0.baseAddress! + outPos).update(from: src.baseAddress!, count: count) }
                    }
                    outPos += count
                }
                if Date() >= nextSample {
                    monitor.sample()
                    nextSample = Date().addingTimeInterval(1)
                }
                if overloaded {
                    clockMs += wall[recorded - 1] + times[.inputResample]
                    if clockMs >= overloadStartMs && clockMs < overloadEndMs { clockMs += overloadExtraMs }
                }
                b += 1
                if overloaded { break }
            }
        }
        let wall = HostTime.ms(from: runStart, to: HostTime.now()) / 1000
        monitor.sample()

        if keepAudio {
            hashes.append(sha256Hex(current[0..<outPos]))
            if run == 1 {
                swap(&reference, &current)
            } else {
                var sum = 0.0
                for i in 0..<outPos {
                    let d = abs(current[i] - reference[i])
                    maxDiff = max(maxDiff, d)
                    sum += Double(d) * Double(d)
                    if d != 0 { bitExact = false }
                }
                let rms = 10 * log10(sum / Double(max(outPos, 1)) + 1e-30)
                worstRmsDB = max(worstRmsDB, rms)
            }
        }

        let runRows = recorder.rows().filter { $0.run == run }
        let audioSec = Double(nBlocks) * blockSec
        summaries.append(Report.RunSummary(index: run, blocks: nBlocks, inferredBlocks: runRows.filter { $0.flags.inferred }.count,
                                           wallSeconds: wall, audioSeconds: audioSec, realTimeFactor: totalMs / 1000 / audioSec,
                                           stages: ReportMath.stageDistributions(runRows)))
        print("run \(run)/\(runs): RTF \(String(format: "%.3f", totalMs / 1000 / audioSec))")
    }

    // Queue model, per run.
    let rows = recorder.rows()
    let blockOut = pipeline.blockOut
    let qc = QueueModel.Config(blockMs: Double(cfg.blockMs), inputRate: deviceRate, inputBufferFrames: inputBuffer,
                               outputRate: outputRate, outputBufferFrames: outputBuffer, blockOut: blockOut,
                               prefill: blockOut / 2, maxFill: blockOut + blockOut / 2)
    var modelled: [QueueModel.Block] = []
    modelled.reserveCapacity(rows.count)
    var under = 0, underFrames = 0, trims = 0, trimFrames = 0
    for run in 1...runs {
        let processing = rows.filter { $0.run == run }.enumerated().map { $1.stages[Stage.inputResample.rawValue] + wall[(run - 1) * nBlocks + $0] }
        let r = QueueModel.run(processingMs: processing, config: qc)
        modelled += r.blocks
        under += r.underrunEvents; underFrames += r.underrunFrames; trims += r.trimEvents; trimFrames += r.trimFrames
    }
    let algorithmic = rows.map(\.algorithmicMs)
    let e2e = zip(modelled, algorithmic).map { $0.pipelineMs + $1 }
    let queue = QueueSummary(inputBufferFrames: inputBuffer, outputBufferFrames: outputBuffer,
                             prefillFrames: qc.prefill, maxFillFrames: qc.maxFill,
                             inputWaitMs: Distribution.of(modelled.map(\.inputWaitMs)),
                             outputQueueMs: Distribution.of(modelled.map(\.outputQueueMs)),
                             pipelineMs: Distribution.of(modelled.map(\.pipelineMs)),
                             algorithmicMs: Distribution.of(algorithmic),
                             endToEndWithoutDevicesMs: Distribution.of(e2e),
                             underrunEvents: under, underrunFrames: underFrames, trimEvents: trims, trimFrames: trimFrames)

    // Memory.
    var perRun: [Double] = []
    for r in 0..<runs {
        let lo = r * nBlocks
        perRun.append(slope(rss[lo..<(lo + nBlocks)]))
    }
    let memory = MemorySummary(rssStartMB: rssStart, rssEndMB: rss[recorded - 1], rssPeakMB: rss.max() ?? 0,
                               footprintPeakMB: footprint.max() ?? 0, lifetimeMaxFootprintMB: lifetimeMaxFootprintMB(),
                               rssSlopeMBPerBlock: slope(rss[...]), footprintSlopeMBPerBlock: slope(footprint[...]),
                               perRunRssSlopeMBPerBlock: perRun)

    // Report.
    var counters = Report.Counters()
    counters.blocks = rows.count
    counters.inferredBlocks = rows.filter { $0.flags.inferred }.count
    counters.gatedBlocks = rows.filter { $0.flags.contains(.gated) }.count
    var config = Report.ConfigInfo(compute: compute.rawValue, blockMs: cfg.blockMs, extraMs: cfg.extraMs, crossfadeMs: cfg.crossfadeMs,
                                   inputRate: deviceRate, outputRate: outputRate, pitch: params.pitch,
                                   indexRatio: Double(params.indexRatio), protect: Double(params.protect), gateDB: Double(params.gateDB))
    config.sourceFile = sourceName
    config.realtimePacing = realtime
    config.warmupBlocks = warmup
    let report = Report(kind: .file, createdAt: Date(), appVersion: "harness",
                        system: SystemProbe.info(thermalStart: thermalStart),
                        model: Report.ModelInfo(name: voice.name, version: voice.version, sampleRate: voice.sr, indexVectors: voice.index?.count),
                        config: config, coldStart: Report.ColdStart(loadMs: loadMs, firstBlockMs: firstBlockMs),
                        stages: ReportMath.stageDistributions(rows), latency: nil, runs: summaries,
                        counters: counters, resources: monitor.summary,
                        notes: ["Offline harness: latency, underrun and queue figures are in queueModel and are calculated, not measured."])

    let determinism = keepAudio && runs >= 2
        ? Determinism(runs: runs, bitExact: bitExact, maxAbsDifference: maxDiff,
                      rmsDifferenceDB: bitExact ? -300 : worstRmsDB, sha256: hashes)
        : nil
    let metrics = HarnessMetrics(commit: gitCommit(in: home), seed: seed, pacing: pacingArg, report: report,
                                 processWallMs: Distribution.of(wall),
                                 memory: memory, queueModel: queue, determinism: determinism)
    try ReportMath.encoder().encode(metrics).write(to: outDir.appendingPathComponent("metrics.json"), options: .atomic)

    // blocks.csv: the report's columns plus memory and the modelled queue figures.
    func cell(_ v: Double, _ format: String = "%.3f") -> String { v.isFinite ? String(format: format, v) : "" }
    var lines = ReportMath.csv(rows).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    lines[0] += ",process_wall_ms,rss_mb,footprint_mb,model_input_wait_ms,model_output_queue_ms,model_pipeline_ms"
    for i in 0..<rows.count {
        let m = modelled[i]
        lines[i + 1] += "," + cell(wall[i]) + "," + cell(rss[i], "%.2f") + "," + cell(footprint[i], "%.2f")
        lines[i + 1] += "," + cell(m.inputWaitMs) + "," + cell(m.outputQueueMs) + "," + cell(m.pipelineMs)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("blocks.csv"), atomically: true, encoding: .utf8)

    if overloaded {
        var csv = ["block,clock_ms,backlog_ms"]
        for i in 0..<recorded { csv.append("\(i),\(String(format: "%.1f", virtualStartMs[i])),\(String(format: "%.1f", backlogMs[i]))") }
        try (csv.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("overload.csv"), atomically: true, encoding: .utf8)
        print("overload: backlog max \(fmt(backlogMs.max() ?? 0)) ms, end \(fmt(backlogMs[recorded - 1])) ms; skipped \(fmt(Double(skipped16.value) / 16)) ms; ring rejected \(inputRing.dropped) frames")
    }

    if keepAudio {
        // `reference` holds run 1
        try ReportStore.writeWAV(Array(reference[0..<min(nBlocks * blockOut, reference.count)]), rate: outputRate,
                                 to: outDir.appendingPathComponent("output.wav"))
    }

    let d = report.stages[Stage.total.key] ?? .empty
    print("block_total p50 \(fmt(d.p50)) p95 \(fmt(d.p95)) p99 \(fmt(d.p99)) max \(fmt(d.max)) ms")
    print("rss \(fmt(memory.rssStartMB)) -> \(fmt(memory.rssEndMB)) MB, slope \(String(format: "%.3f", memory.rssSlopeMBPerBlock)) MB/block")
    print("wrote \(outDir.path)")
}

// The live worker is a dedicated Thread with this QoS and no autorelease pool of its own; match it.
let done = DispatchSemaphore(value: 0)
var failure: String?
let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(usage)\n".utf8))
    exit(2)
}
let worker = Thread {
    do {
        try runHarness(options)
    } catch {
        failure = "\(error)"
    }
    done.signal()
}
worker.qualityOfService = .userInteractive
worker.name = "RVCMac.harness"
worker.start()
done.wait()
if let failure {
    FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
    exit(1)
}
