import AppKit
import AVFoundation
import CoreML
import Foundation
import SwiftUI

enum ComputeChoice: String, CaseIterable, Identifiable {
    case neuralEngine = "Neural Engine + GPU"
    case aneOnly = "Neural Engine"
    case gpu = "GPU"
    case cpu = "CPU"
    var id: String { rawValue }
    var units: MLComputeUnits {
        switch self {
        case .neuralEngine: return .all
        case .aneOnly: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // library
    @Published var voices: [VoiceInfo] = []
    @Published var selectedVoice: String = UserDefaults.standard.string(forKey: "voice") ?? "" {
        didSet { UserDefaults.standard.set(selectedVoice, forKey: "voice") }
    }

    // latency
    @Published var blockMs: Int = UserDefaults.standard.object(forKey: "blockMs") as? Int ?? 250 {
        didSet { UserDefaults.standard.set(blockMs, forKey: "blockMs") }
    }
    @Published var extraMs: Int = UserDefaults.standard.object(forKey: "extraMs") as? Int ?? 500 {
        didSet { UserDefaults.standard.set(extraMs, forKey: "extraMs") }
    }
    @Published var crossfadeMs: Int = UserDefaults.standard.object(forKey: "crossfadeMs") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(crossfadeMs, forKey: "crossfadeMs") }
    }
    @Published var compute: ComputeChoice = ComputeChoice(rawValue: UserDefaults.standard.string(forKey: "compute") ?? "") ?? .neuralEngine {
        didSet { UserDefaults.standard.set(compute.rawValue, forKey: "compute") }
    }

    // devices
    @Published var inputs: [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []
    @Published var inputUID: String = UserDefaults.standard.string(forKey: "inputUID") ?? "" {
        didSet { UserDefaults.standard.set(inputUID, forKey: "inputUID") }
    }
    @Published var outputUID: String = UserDefaults.standard.string(forKey: "outputUID") ?? "" {
        didSet { UserDefaults.standard.set(outputUID, forKey: "outputUID") }
    }

    // live params
    @Published var pitch: Double = UserDefaults.standard.object(forKey: "pitch") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(pitch, forKey: "pitch"); pushParams() }
    }
    @Published var gateDB: Double = UserDefaults.standard.object(forKey: "gateDB") as? Double ?? -60 {
        didSet { UserDefaults.standard.set(gateDB, forKey: "gateDB"); pushParams() }
    }
    @Published var gain: Double = UserDefaults.standard.object(forKey: "gain") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(gain, forKey: "gain"); pushParams() }
    }
    @Published var indexRatio: Double = UserDefaults.standard.object(forKey: "indexRatio") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(indexRatio, forKey: "indexRatio"); pushParams() }
    }
    @Published var protect: Double = UserDefaults.standard.object(forKey: "protect") as? Double ?? 0.33 {
        didSet { UserDefaults.standard.set(protect, forKey: "protect"); pushParams() }
    }
    @Published var bypass = false { didSet { pushParams() } }

    // status
    @Published var running = false
    @Published var busy = false
    @Published var status = "Остановлено"
    @Published var stats = EngineStats()
    @Published var log = ""

    private var engine: VoiceEngine?
    private var converter: Process?

    init() {
        refreshDevices()
        refreshVoices()
    }

    // MARK: library / devices

    func refreshVoices() {
        voices = ModelLibrary.voices()
        if !voices.contains(where: { $0.name == selectedVoice }) { selectedVoice = voices.first?.name ?? "" }
    }

    func refreshDevices() {
        let all = AudioDevices.all()
        inputs = all.filter { $0.inputChannels > 0 }
        outputs = all.filter { $0.outputChannels > 0 }
        if !inputs.contains(where: { $0.uid == inputUID }) {
            let def = AudioDevices.defaultDevice(input: true)
            inputUID = inputs.first(where: { $0.id == def })?.uid ?? inputs.first?.uid ?? ""
        }
        if !outputs.contains(where: { $0.uid == outputUID }) {
            let blackhole = outputs.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
            let def = AudioDevices.defaultDevice(input: false)
            outputUID = blackhole?.uid ?? outputs.first(where: { $0.id == def })?.uid ?? outputs.first?.uid ?? ""
        }
    }

    var currentVoice: VoiceInfo? { voices.first { $0.name == selectedVoice } }
    var currentKey: String { LatencyConfig.key(block: blockMs, extra: extraMs, crossfade: crossfadeMs) }
    /// Only index-capable synth builds (phoneFrames set) are usable; older builds need "Собрать".
    var currentConfig: LatencyConfig? {
        currentVoice?.configs.values.first { $0.key == currentKey && $0.phoneFrames != nil }
    }

    // MARK: engine

    private func pushParams() {
        guard let engine else { return }
        var p = EngineParams()
        p.pitch = Int(pitch.rounded())
        p.gateDB = Float(gateDB)
        p.gain = Float(gain)
        p.bypass = bypass
        p.indexRatio = Float(indexRatio)
        p.protect = Float(protect)
        engine.params = p
    }

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard let voice = currentVoice else { appendLog("Нет выбранного голоса — импортируй модель."); return }
        guard let cfg = currentConfig else { appendLog("Для этих настроек задержки модель ещё не сконвертирована."); return }
        guard let input = inputs.first(where: { $0.uid == inputUID }),
              let output = outputs.first(where: { $0.uid == outputUID }) else {
            appendLog("Выбери устройства ввода и вывода."); return
        }
        busy = true
        status = "Загрузка моделей (первый раз Neural Engine компилирует их до минуты)…"
        let units = compute.units
        Task.detached(priority: .userInitiated) {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                await MainActor.run {
                    self.busy = false
                    self.status = "Нет доступа к микрофону"
                    self.appendLog("Разреши микрофон: Системные настройки → Конфиденциальность → Микрофон → RVCMac.")
                }
                return
            }
            do {
                let t0 = Date()
                let loaded = try LoadedVoice(voice: voice, config: cfg, units: units)
                let engine = try VoiceEngine(model: loaded)
                let loadTime = Date().timeIntervalSince(t0)
                await MainActor.run {
                    engine.onStats = { s in Task { @MainActor in self.stats = s } }
                    engine.onError = { msg in Task { @MainActor in self.appendLog(msg); self.stop() } }
                    self.engine = engine
                    self.pushParams()
                    do {
                        try engine.start(input: input.id, output: output.id)
                        self.running = true
                        self.status = "Работает: \(voice.name) · \(input.name) → \(output.name)"
                        self.appendLog(String(format: "Модели загружены за %.1f с (%@).", loadTime, self.compute.rawValue))
                    } catch {
                        self.engine = nil
                        self.status = "Ошибка запуска аудио"
                        self.appendLog("Аудио: \(error.localizedDescription)")
                    }
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "Ошибка загрузки модели"
                    self.appendLog("Модель: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        running = false
        status = "Остановлено"
    }

    // MARK: converter

    func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Выбери RVC-модель (.pth или .safetensors)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "pth" || ext == "safetensors" else { appendLog("Нужен файл .pth или .safetensors"); return }
        runConverter(["import", "--model", url.path] + latencyArgs())
    }

    func addIndex() {
        guard let v = currentVoice else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Выбери .index для голоса \(v.name) (added_*.index)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "index" else { appendLog("Нужен файл .index"); return }
        runConverter(["index", "--name", v.name, "--index", url.path])
    }

    func convertCurrentConfig() {
        guard let v = currentVoice else { return }
        runConverter(["config", "--name", v.name] + latencyArgs())
    }

    private func latencyArgs() -> [String] {
        ["--block-ms", "\(blockMs)", "--extra-ms", "\(extraMs)", "--crossfade-ms", "\(crossfadeMs)"]
    }

    private func runConverter(_ args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: RVCMacPaths.python.path) else {
            appendLog("Не найден Python конвертера: \(RVCMacPaths.python.path). Запусти scripts/setup_converter.sh.")
            return
        }
        if running { stop() }
        busy = true
        status = "Конвертация модели…"
        appendLog("$ convert.py " + args.joined(separator: " "))
        let p = Process()
        p.executableURL = RVCMacPaths.python
        p.arguments = [RVCMacPaths.converter.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.appendLog(s, newline: false) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self.busy = false
                self.converter = nil
                if proc.terminationStatus == 0 {
                    self.status = "Конвертация завершена"
                } else {
                    self.status = "Конвертация упала (код \(proc.terminationStatus)) — см. лог"
                }
                self.refreshVoices()
            }
        }
        do {
            try p.run()
            converter = p
        } catch {
            busy = false
            appendLog("Не удалось запустить конвертер: \(error.localizedDescription)")
        }
    }

    func appendLog(_ s: String, newline: Bool = true) {
        log += s + (newline ? "\n" : "")
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
        // mirror to a file so problems can be inspected outside the app
        let url = RVCMacPaths.home.appendingPathComponent("app.log")
        let line = s + (newline ? "\n" : "")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
