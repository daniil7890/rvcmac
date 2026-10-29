import AppKit
import AVFoundation
import CoreAudio
import CoreML
import Foundation
import RVCMacCore
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

struct ChartPoint: Identifiable {
    let id: Int
    let t: Double
    let endToEnd: Double
    let processMs: Double
}

@MainActor
final class AppState: ObservableObject {
    private let defaults = UserDefaults.standard

    // library
    @Published var voices: [VoiceInfo] = []
    @Published var voiceIssues: [String: [String]] = [:]
    @Published var selectedVoice: String = UserDefaults.standard.string(forKey: "voice") ?? "" {
        didSet {
            defaults.set(selectedVoice, forKey: "voice")
            if oldValue != selectedVoice && running && !applyingProfile { switchVoiceLive() }
        }
    }

    // latency
    @Published var blockMs: Int = UserDefaults.standard.object(forKey: "blockMs") as? Int ?? 250 {
        didSet { defaults.set(blockMs, forKey: "blockMs") }
    }
    @Published var extraMs: Int = UserDefaults.standard.object(forKey: "extraMs") as? Int ?? 500 {
        didSet { defaults.set(extraMs, forKey: "extraMs") }
    }
    @Published var crossfadeMs: Int = UserDefaults.standard.object(forKey: "crossfadeMs") as? Int ?? 100 {
        didSet { defaults.set(crossfadeMs, forKey: "crossfadeMs") }
    }
    @Published var compute: ComputeChoice = ComputeChoice(rawValue: UserDefaults.standard.string(forKey: "compute") ?? "") ?? .neuralEngine {
        didSet { defaults.set(compute.rawValue, forKey: "compute") }
    }

    // devices
    @Published var inputs: [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []
    @Published var inputUID: String = UserDefaults.standard.string(forKey: "inputUID") ?? "" {
        didSet { defaults.set(inputUID, forKey: "inputUID") }
    }
    @Published var outputUID: String = UserDefaults.standard.string(forKey: "outputUID") ?? "" {
        didSet { defaults.set(outputUID, forKey: "outputUID") }
    }

    // live params
    @Published var pitch: Double = UserDefaults.standard.object(forKey: "pitch") as? Double ?? 0 {
        didSet { defaults.set(pitch, forKey: "pitch"); pushParams() }
    }
    @Published var gateDB: Double = UserDefaults.standard.object(forKey: "gateDB") as? Double ?? -60 {
        didSet { defaults.set(gateDB, forKey: "gateDB"); pushParams() }
    }
    @Published var gain: Double = UserDefaults.standard.object(forKey: "gain") as? Double ?? 1 {
        didSet { defaults.set(gain, forKey: "gain"); pushParams() }
    }
    @Published var indexRatio: Double = UserDefaults.standard.object(forKey: "indexRatio") as? Double ?? 0.5 {
        didSet { defaults.set(indexRatio, forKey: "indexRatio"); pushParams() }
    }
    @Published var protect: Double = UserDefaults.standard.object(forKey: "protect") as? Double ?? 0.33 {
        didSet { defaults.set(protect, forKey: "protect"); pushParams() }
    }
    @Published var bypass = false { didSet { pushParams() } }

    // mute / push-to-talk (applied in the output callback with a short ramp)
    @Published var muted = false { didSet { pushMute() } }
    @Published var pushToTalk: Bool = UserDefaults.standard.bool(forKey: "pushToTalk") {
        didSet { defaults.set(pushToTalk, forKey: "pushToTalk"); pushMute() }
    }
    @Published var pttHeld = false { didSet { pushMute() } }
    var effectiveMuted: Bool { muted || (pushToTalk && !pttHeld) }

    // profiles
    @Published var profiles: [Profile] = []
    @Published var activeProfileID: UUID? = UserDefaults.standard.string(forKey: "activeProfile").flatMap { UUID(uuidString: $0) } {
        didSet { defaults.set(activeProfileID?.uuidString, forKey: "activeProfile") }
    }
    private var applyingProfile = false
    private let profileStore = ProfileStore(url: RVCMacPaths.home.appendingPathComponent("profiles.json"))

    // hotkeys
    @Published var hotkeys: [HotkeyAction: Hotkey] = [:] {
        didSet { saveHotkeys(); registerHotkeys() }
    }
    @Published var hotkeyFailures: [HotkeyAction] = []

    // settings
    @Published var keepInMenuBar: Bool = UserDefaults.standard.bool(forKey: "keepInMenuBar") {
        didSet { defaults.set(keepInMenuBar, forKey: "keepInMenuBar") }
    }
    @Published var anonymizeReports: Bool = UserDefaults.standard.object(forKey: "anonymizeReports") as? Bool ?? true {
        didSet { defaults.set(anonymizeReports, forKey: "anonymizeReports") }
    }

    // status
    @Published var running = false
    @Published var busy = false
    @Published var status = "Остановлено"
    @Published var lastError: String?
    @Published var stats = EngineStats()
    @Published var resources = ResourceMonitor.Sample(cpuPercent: 0, memoryMB: 0, thermal: SystemProbe.thermalName())
    @Published var chart: [ChartPoint] = []
    @Published var log = ""

    // benchmark / reports
    @Published var benchRunning = false
    @Published var benchProgress = ""
    @Published var benchRuns = 3
    @Published var benchPacing = true
    @Published var benchSaveAudio = true
    @Published var benchFile: URL?
    @Published var reportFiles: [URL] = []
    @Published var lastReport: Report?
    private let benchCancel = AtomicInt(0)

    private var engine: VoiceEngine?
    private var converter: Process?
    private var sessionInput = ""
    private var sessionOutput = ""
    private var sessionLoadMs = 0.0
    private var lastSession: (report: Report, rows: [BlockRow])?
    private let monitor = ResourceMonitor()
    private var timer: Timer?
    private var chartCounter = 0
    private var chartStart = Date()
    private let logQueue = DispatchQueue(label: "RVCMac.log", qos: .utility)
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        refreshVoices()
        profiles = profileStore.load()
        loadHotkeys()  // didSet registers them
        HotkeyManager.shared.onEvent = { [weak self] action, pressed in
            Task { @MainActor in self?.hotkey(action, pressed: pressed) }
        }
        reportFiles = ReportStore.list()
        watchDeviceList()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: library / devices

    func refreshVoices() {
        voices = ModelLibrary.voices()
        var issues: [String: [String]] = [:]
        for v in voices {
            let i = ModelLibrary.validate(v)
            if !i.isEmpty { issues[v.name] = i }
        }
        voiceIssues = issues
        if !voices.contains(where: { $0.name == selectedVoice }) {
            applyingProfile = true
            selectedVoice = voices.first?.name ?? ""
            applyingProfile = false
        }
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

    private func watchDeviceList() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.running else { return }
                self.refreshDevices()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block) == noErr {
            deviceListener = block
        }
    }

    var currentVoice: VoiceInfo? { voices.first { $0.name == selectedVoice } }
    var currentKey: String { LatencyConfig.key(block: blockMs, extra: extraMs, crossfade: crossfadeMs) }
    /// Only index-capable synth builds (phoneFrames set) are usable; older builds need "Собрать".
    var currentConfig: LatencyConfig? { config(for: currentVoice) }
    func config(for voice: VoiceInfo?) -> LatencyConfig? {
        voice?.configs.values.first { $0.key == currentKey && $0.phoneFrames != nil }
    }

    // MARK: engine

    private var engineParams: EngineParams {
        var p = EngineParams()
        p.pitch = Int(pitch.rounded())
        p.gateDB = Float(gateDB)
        p.gain = Float(gain)
        p.bypass = bypass
        p.indexRatio = Float(indexRatio)
        p.protect = Float(protect)
        return p
    }

    private func pushParams() {
        engine?.params = engineParams
    }

    private func pushMute() {
        engine?.muted = effectiveMuted
    }

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard !benchRunning else { appendLog("Дождись окончания бенчмарка."); return }
        guard let voice = currentVoice else { appendLog("Нет выбранного голоса — импортируй модель."); return }
        guard let cfg = currentConfig else { appendLog("Для этих настроек задержки модель ещё не сконвертирована."); return }
        guard let input = inputs.first(where: { $0.uid == inputUID }),
              let output = outputs.first(where: { $0.uid == outputUID }) else {
            appendLog("Выбери устройства ввода и вывода."); return
        }
        if input.uid == output.uid && AudioDevices.isVirtual(input.id) {
            // a virtual loopback device as both input and output feeds our output straight back in
            appendLog("Вход и выход — одно виртуальное устройство (\(input.name)): звук пойдёт по кругу. Выбери физический микрофон.")
            return
        }
        busy = true
        lastError = nil
        status = "Загрузка моделей (первый раз Neural Engine компилирует их до минуты)…"
        let units = compute.units
        let computeName = compute.rawValue
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
                let engine = VoiceEngine(model: loaded)
                let loadTime = Date().timeIntervalSince(t0)
                await MainActor.run {
                    engine.onStats = { s in Task { @MainActor in self.receive(s) } }
                    engine.onError = { msg in Task { @MainActor in self.fail(msg) } }
                    engine.onModelSwitched = { name, ms in
                        Task { @MainActor in self.appendLog(String(format: "Голос переключён на %@ за %.0f мс (с ожиданием границы блока).", name, ms)) }
                    }
                    engine.io.onDeviceEvent = { ev in Task { @MainActor in self.deviceEvent(ev) } }
                    self.engine = engine
                    self.pushParams()
                    self.pushMute()
                    do {
                        try engine.start(input: input.id, output: output.id)
                        self.running = true
                        self.sessionInput = input.name
                        self.sessionOutput = output.name
                        self.sessionLoadMs = loadTime * 1000
                        self.monitor.reset()
                        self.chart.removeAll()
                        self.chartStart = Date()
                        self.status = "Работает: \(voice.name) · \(input.name) → \(output.name)"
                        self.appendLog(String(format: "Модели загружены за %.1f с (%@). Устройства: вход %.1f мс, выход %.1f мс по данным Core Audio.",
                                              loadTime, computeName, engine.io.inputLatencyMs, engine.io.outputLatencyMs))
                    } catch {
                        self.engine = nil
                        self.status = "Ошибка запуска аудио"
                        self.lastError = error.localizedDescription
                        self.appendLog("Аудио: \(error.localizedDescription)")
                    }
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "Ошибка загрузки модели"
                    self.lastError = error.localizedDescription
                    self.appendLog("Модель: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        if let engine {
            lastSession = makeLiveReport(engine)
            engine.stop()
            if let r = lastSession?.report { appendLog(summaryLine(r)) }
        }
        engine = nil
        running = false
        pttHeld = false
        status = "Остановлено"
    }

    private func restart() {
        stop()
        start()
    }

    private func fail(_ msg: String) {
        appendLog(msg)
        lastError = msg
        stop()
        status = "Остановлено из-за ошибки"
    }

    private func deviceEvent(_ ev: DeviceEvent) {
        switch ev {
        case let .disconnected(name):
            fail("Устройство «\(name)» отключилось. Обработка остановлена.")
            refreshDevices()
        case let .sampleRateChanged(name):
            appendLog("У «\(name)» сменилась частота дискретизации — перезапускаю аудио.")
            restart()
        }
    }

    private func receive(_ s: EngineStats) {
        stats = s
        guard s.endToEnd.count > 0 || s.processMs > 0 else { return }
        chartCounter += 1
        chart.append(ChartPoint(id: chartCounter, t: Date().timeIntervalSince(chartStart),
                                endToEnd: s.endToEnd.count > 0 ? s.endToEnd.p50 : .nan, processMs: s.processMs))
        if chart.count > 400 { chart.removeFirst(chart.count - 400) }
    }

    private func tick() {
        resources = monitor.sample()
    }

    /// Switches the voice without stopping audio (same latency settings): the new models are
    /// prepared in the background and the SOLA crossfade blends the voices.
    private func switchVoiceLive() {
        guard let engine, let voice = currentVoice else { return }
        guard let cfg = config(for: voice) else {
            appendLog("У «\(voice.name)» нет сборки \(currentKey) — переключение на лету невозможно. Останови и нажми «Собрать».")
            revertVoiceSelection(to: engine)
            return
        }
        let units = compute.units
        appendLog("Готовлю голос \(voice.name)…")
        Task.detached(priority: .userInitiated) {
            do {
                let loaded = try LoadedVoice(voice: voice, config: cfg, units: units)
                try engine.switchModel(to: loaded)
            } catch {
                await MainActor.run {
                    self.appendLog("Переключение голоса: \(error.localizedDescription)")
                    self.revertVoiceSelection(to: engine)
                }
            }
        }
    }

    /// Keeps the picker in sync with what is actually playing after a failed switch.
    private func revertVoiceSelection(to engine: VoiceEngine) {
        applyingProfile = true
        selectedVoice = engine.currentModel.voice.name
        applyingProfile = false
    }

    // MARK: profiles

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }

    private func currentAsProfile(name: String, id: UUID = UUID()) -> Profile {
        Profile(id: id, name: name, voice: selectedVoice, blockMs: blockMs, extraMs: extraMs, crossfadeMs: crossfadeMs,
                compute: compute.rawValue, pitch: pitch, gateDB: gateDB, gain: gain, indexRatio: indexRatio, protect: protect)
    }

    func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let i = profiles.firstIndex(where: { $0.name == trimmed }) {
            profiles[i] = currentAsProfile(name: trimmed, id: profiles[i].id)
            activeProfileID = profiles[i].id
        } else {
            let p = currentAsProfile(name: trimmed)
            profiles.append(p)
            activeProfileID = p.id
        }
        persistProfiles()
    }

    func updateActiveProfile() {
        guard let p = activeProfile else { return }
        saveProfile(named: p.name)
    }

    func deleteActiveProfile() {
        guard let id = activeProfileID else { return }
        profiles.removeAll { $0.id == id }
        activeProfileID = nil
        persistProfiles()
    }

    private func persistProfiles() {
        do { try profileStore.save(profiles) } catch { appendLog("Профили: \(error.localizedDescription)") }
    }

    func applyProfile(_ p: Profile) {
        let before = currentAsProfile(name: "")
        let needsRestart = running && (p.latencyKey != before.latencyKey || p.compute != before.compute)
        let voiceChanged = p.voice != selectedVoice
        applyingProfile = true
        if voices.contains(where: { $0.name == p.voice }) {
            selectedVoice = p.voice
        } else {
            appendLog("В профиле «\(p.name)» голос \(p.voice), но его нет в библиотеке.")
        }
        blockMs = p.blockMs
        extraMs = p.extraMs
        crossfadeMs = p.crossfadeMs
        compute = ComputeChoice(rawValue: p.compute) ?? compute
        pitch = p.pitch
        gateDB = p.gateDB
        gain = p.gain
        indexRatio = p.indexRatio
        protect = p.protect
        applyingProfile = false
        activeProfileID = p.id
        if running {
            if needsRestart {
                appendLog("Профиль «\(p.name)» меняет задержку или вычисления — перезапуск.")
                restart()
            } else if voiceChanged {
                switchVoiceLive()
            }
        }
    }

    func nextProfile() {
        guard !profiles.isEmpty else { return }
        let i = profiles.firstIndex { $0.id == activeProfileID } ?? -1
        applyProfile(profiles[(i + 1) % profiles.count])
    }

    // MARK: hotkeys

    private func loadHotkeys() {
        if let data = defaults.data(forKey: "hotkeys"), let map = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            var m: [HotkeyAction: Hotkey] = [:]
            for (k, v) in map { if let a = HotkeyAction(rawValue: k) { m[a] = v } }
            hotkeys = m
        } else {
            hotkeys = Hotkey.defaults
        }
    }

    private func saveHotkeys() {
        let map = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: "hotkeys") }
    }

    private func registerHotkeys() {
        hotkeyFailures = HotkeyManager.shared.register(hotkeys)
        if !hotkeyFailures.isEmpty {
            appendLog("Не удалось назначить: " + hotkeyFailures.map(\.title).joined(separator: ", ") + " (сочетание занято).")
        }
    }

    func resetHotkeys() { hotkeys = Hotkey.defaults }

    private func hotkey(_ action: HotkeyAction, pressed: Bool) {
        switch action {
        case .pushToTalk:
            pttHeld = pressed
        case .toggleRun where pressed:
            if !busy { toggle() }
        case .mute where pressed:
            muted.toggle()
        case .bypass where pressed:
            bypass.toggle()
        case .nextProfile where pressed:
            nextProfile()
        default:
            break
        }
    }

    // MARK: reports

    private func makeLiveReport(_ engine: VoiceEngine) -> (report: Report, rows: [BlockRow]) {
        let rows = engine.sessionRows()
        let model = engine.currentModel
        let cfg = model.config
        var config = Report.ConfigInfo(compute: compute.rawValue, blockMs: cfg.blockMs, extraMs: cfg.extraMs, crossfadeMs: cfg.crossfadeMs,
                                       inputRate: engine.io.inputRate, outputRate: engine.io.outputRate,
                                       pitch: Int(pitch.rounded()), indexRatio: indexRatio, protect: protect, gateDB: gateDB)
        if !anonymizeReports {
            config.inputDevice = sessionInput
            config.outputDevice = sessionOutput
        }
        let wall = Date().timeIntervalSince(engine.sessionStarted)
        let inferred = rows.filter { $0.flags.inferred }
        let totalMs = inferred.reduce(0) { $0 + $1.stages[Stage.total.rawValue] }
        let audioSec = Double(rows.count) * Double(cfg.blockMs) / 1000
        let run = Report.RunSummary(index: 1, blocks: rows.count, inferredBlocks: inferred.count, wallSeconds: wall,
                                    audioSeconds: audioSec, realTimeFactor: audioSec > 0 ? totalMs / 1000 / audioSec : 0,
                                    stages: ReportMath.stageDistributions(rows))
        var counters = engine.counters(rows: rows)
        counters.errors = lastError == nil ? 0 : 1
        var notes = [
            "Полная задержка = конвейер (захват последнего сэмпла блока → воспроизведение первого сэмпла результата) + алгоритмическая (блок + кроссфейд + SOLA − смещение) + задержки устройств по данным Core Audio.",
            "Задержка ресемплера AVAudioConverter (единицы мс) не учитывается.",
        ]
        if counters.modelSwitches > 0 { notes.append("Голос переключался во время сессии: \(counters.modelSwitches) раз.") }
        let report = Report(kind: .live, createdAt: Date(), appVersion: SystemProbe.appVersion,
                            system: SystemProbe.info(thermalStart: monitor.samples.first?.thermal ?? SystemProbe.thermalName()),
                            model: Report.ModelInfo(name: model.voice.name, version: model.voice.version, sampleRate: model.voice.sr,
                                                    indexVectors: model.voice.index?.count),
                            config: config,
                            coldStart: Report.ColdStart(loadMs: sessionLoadMs, firstBlockMs: rows.first(where: { $0.flags.inferred })?.stages[Stage.total.rawValue] ?? .nan),
                            stages: ReportMath.stageDistributions(rows),
                            latency: ReportMath.latency(rows, deviceInputMs: engine.io.inputLatencyMs, deviceOutputMs: engine.io.outputLatencyMs),
                            runs: [run], counters: counters, resources: monitor.summary, notes: notes)
        return (report, rows)
    }

    private func summaryLine(_ r: Report) -> String {
        var s = "Сессия: \(r.counters.blocks) блоков"
        if let l = r.latency, l.endToEnd.count > 0 {
            s += String(format: ", задержка p50 %.0f / p95 %.0f / p99 %.0f мс", l.endToEnd.p50, l.endToEnd.p95, l.endToEnd.p99)
        }
        if let t = r.stages[Stage.total.key], t.count > 0 {
            s += String(format: ", обработка блока p95 %.0f мс", t.p95)
        }
        s += ", underrun \(r.counters.underrunEvents)."
        return s
    }

    var canExportSession: Bool { engine != nil || lastSession != nil }

    func exportSessionReport() {
        let snapshot = engine.map { makeLiveReport($0) } ?? lastSession
        guard let snapshot else { appendLog("Нет данных сессии — запусти обработку."); return }
        Task.detached(priority: .utility) {
            do {
                let url = try ReportStore.save(snapshot.report, rows: snapshot.rows)
                await MainActor.run {
                    self.lastReport = snapshot.report
                    self.reportFiles = ReportStore.list()
                    self.appendLog("Отчёт сохранён: \(url.path) (+ .csv)")
                }
            } catch {
                await MainActor.run { self.appendLog("Отчёт: \(error.localizedDescription)") }
            }
        }
    }

    func chooseBenchmarkFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Аудиофайл для бенчмарка (wav, aiff, m4a, mp3…)"
        if panel.runModal() == .OK { benchFile = panel.url }
    }

    func runBenchmark() {
        guard !running else { appendLog("Останови обработку: бенчмарк и live-режим делят Neural Engine."); return }
        guard let voice = currentVoice, let cfg = currentConfig else { appendLog("Выбери голос с собранной конфигурацией."); return }
        var options = BenchmarkOptions()
        options.sourceURL = benchFile
        options.runs = max(1, benchRuns)
        options.realtimePacing = benchPacing
        options.saveOutput = benchSaveAudio
        let compute = self.compute
        let params = engineParams
        let cancel = benchCancel
        cancel.value = 0
        benchRunning = true
        benchProgress = "Старт…"
        appendLog("Бенчмарк: \(voice.name), \(cfg.key), \(compute.rawValue), прогонов \(options.runs), \(benchFile?.lastPathComponent ?? "синтетический сигнал").")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try BenchmarkRunner.run(voice: voice, config: cfg, compute: compute, params: params, options: options,
                                                     progress: { msg in Task { @MainActor in self.benchProgress = msg } },
                                                     isCancelled: { cancel.value != 0 })
                let url = try ReportStore.save(result.report, rows: result.rows,
                                               audio: options.saveOutput ? result.output : nil, sampleRate: options.outputRate)
                await MainActor.run {
                    self.benchRunning = false
                    self.benchProgress = "Готово"
                    self.lastReport = result.report
                    self.reportFiles = ReportStore.list()
                    self.appendLog(self.benchmarkLine(result.report))
                    self.appendLog("Отчёт: \(url.path)")
                }
            } catch {
                await MainActor.run {
                    self.benchRunning = false
                    self.benchProgress = error.localizedDescription
                    self.appendLog("Бенчмарк: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelBenchmark() { benchCancel.value = 1 }

    private func benchmarkLine(_ r: Report) -> String {
        var s = "Бенчмарк готов"
        if let c = r.coldStart { s += String(format: ": загрузка %.0f мс, первый блок %.0f мс", c.loadMs, c.firstBlockMs) }
        if let t = r.stages[Stage.total.key] {
            s += String(format: "; блок p50 %.1f / p95 %.1f / p99 %.1f мс", t.p50, t.p95, t.p99)
        }
        let rtf = r.runs.map(\.realTimeFactor)
        if !rtf.isEmpty { s += String(format: "; RTF %.2f", rtf.reduce(0, +) / Double(rtf.count)) }
        return s + "."
    }

    func refreshReports() { reportFiles = ReportStore.list() }

    func revealReports() {
        try? FileManager.default.createDirectory(at: ReportStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([ReportStore.directory])
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
                    if self.log.suffix(3000).contains("--unsafe-pickle"), !args.contains("--unsafe-pickle") {
                        self.offerUnsafeRetry(args)
                    }
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

    /// A .pth that is not plain weights is only loaded after an explicit confirmation.
    private func offerUnsafeRetry(_ args: [String]) {
        let alert = NSAlert()
        alert.messageText = "Модель не прошла безопасную загрузку"
        alert.informativeText = "Файл .pth содержит не только веса. Полная загрузка pickle может выполнить код из файла. Продолжай, только если доверяешь источнику модели. Лучше найти версию .safetensors."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Доверяю, загрузить")
        if alert.runModal() == .alertSecondButtonReturn {
            runConverter(args + ["--unsafe-pickle"])
        }
    }

    func appendLog(_ s: String, newline: Bool = true) {
        let line = s + (newline ? "\n" : "")
        log += line
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
        // mirror to a file so problems can be inspected outside the app (off the main thread)
        let url = RVCMacPaths.home.appendingPathComponent("app.log")
        logQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
