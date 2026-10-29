import AppKit
import RVCMacCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // the Dock shows this even when the system icon cache still holds an older build
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With "keep in menu bar" on, closing the window leaves the engine running behind the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "keepInMenuBar")
    }
}

@main
struct RVCMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("RVCMac", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 600, minHeight: 700)
        }
        .windowResizability(.contentMinSize)

        Window(tr("Диагностика"), id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 620)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        if !state.running { return "waveform.circle" }
        if state.effectiveMuted { return "mic.slash.circle.fill" }
        if state.bypass { return "arrow.left.and.right.circle" }
        return "waveform.circle.fill"
    }
}

// MARK: - Main window

/// View-local state (see DiagnosticsUI for why this is not @State).
final class ContentUI: ObservableObject {
    @Published var newProfileName = ""
    @Published var askProfileName = false
}

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = ContentUI()

    private let blockOptions = [80, 100, 120, 150, 200, 250, 300, 350, 400, 500]
    private let extraOptions = [200, 300, 500, 750, 1000]
    private let crossfadeOptions = [50, 100, 150, 200]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(tr("Профиль")) {
                    HStack {
                        Picker(tr("Профиль"), selection: Binding(
                            get: { s.activeProfileID },
                            set: { id in if let p = s.profiles.first(where: { $0.id == id }) { s.applyProfile(p) } else { s.activeProfileID = nil } }
                        )) {
                            Text(tr("— без профиля —")).tag(UUID?.none)
                            ForEach(s.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        Button(tr("Сохранить")) { s.updateActiveProfile() }
                            .disabled(s.activeProfile == nil)
                            .help(tr("Записать текущие настройки в выбранный профиль"))
                        Button(tr("Новый…")) { ui.newProfileName = ""; ui.askProfileName = true }
                        Button(role: .destructive) { s.deleteActiveProfile() } label: { Image(systemName: "trash") }
                            .disabled(s.activeProfile == nil)
                            .help(tr("Удалить профиль"))
                    }
                }

                Section(tr("Голос")) {
                    HStack {
                        Picker(tr("Модель"), selection: $s.selectedVoice) {
                            if s.voices.isEmpty { Text(tr("— нет моделей —")).tag("") }
                            ForEach(s.voices, id: \.name) { v in
                                Text(trf("%@%@  ·  %@ · %@ кГц", "\(s.voiceIssues[v.name] == nil ? "" : "⚠︎ ")", "\(v.name)", "\(v.version)", "\(v.sr / 1000)")).tag(v.name)
                            }
                        }
                        .disabled(s.busy)
                        .help(s.running ? tr("Смена голоса на лету: новый голос готовится в фоне и подмешивается кроссфейдом") : "")
                        Group {
                            Button(tr("Импорт…")) { s.importModel() }
                            Button("Index…") { s.addIndex() }
                                .disabled(s.currentVoice == nil)
                                .help(tr("Подключить .index к выбранному голосу"))
                            Button { s.refreshVoices() } label: { Image(systemName: "arrow.clockwise") }
                                .help(tr("Обновить список"))
                        }
                        .disabled(s.busy || s.running)
                    }
                    if let issues = s.voiceIssues[s.selectedVoice] {
                        Text(tr("Проблемы модели: ") + issues.joined(separator: "; "))
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                Section(tr("Задержка")) {
                    HStack {
                        Picker(tr("Блок"), selection: $s.blockMs) {
                            ForEach(blockOptions, id: \.self) { Text(trf("%@ мс", "\($0)")).tag($0) }
                        }
                        Picker(tr("Контекст"), selection: $s.extraMs) {
                            ForEach(extraOptions, id: \.self) { Text(trf("%@ мс", "\($0)")).tag($0) }
                        }
                        Picker(tr("Кроссфейд"), selection: $s.crossfadeMs) {
                            ForEach(crossfadeOptions, id: \.self) { Text(trf("%@ мс", "\($0)")).tag($0) }
                        }
                    }
                    .disabled(s.busy || s.running)
                    if s.currentVoice != nil && s.currentConfig == nil {
                        HStack {
                            Text(tr("Под эти настройки модель ещё не собрана (или собрана старой версией)."))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(tr("Собрать")) { s.convertCurrentConfig() }.disabled(s.busy)
                        }
                    }
                    Picker(tr("Вычисления"), selection: $s.compute) {
                        ForEach(ComputeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(s.busy || s.running)
                }

                Section(tr("Аудио")) {
                    HStack {
                        Picker(tr("Вход"), selection: $s.inputUID) {
                            ForEach(s.inputs) { Text($0.name).tag($0.uid) }
                        }
                        Button { s.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .help(tr("Обновить устройства"))
                    }
                    Picker(tr("Выход"), selection: $s.outputUID) {
                        ForEach(s.outputs) { Text($0.name).tag($0.uid) }
                    }
                }
                .disabled(s.busy || s.running)

                Section(tr("Звук")) {
                    LabeledContent(trf("Тон: %@ пт", "\(Int(s.pitch.rounded()))")) {
                        Slider(value: $s.pitch, in: -24...24, step: 1)
                    }
                    LabeledContent(trf("Порог тишины: %@ дБ", "\(Int(s.gateDB))")) {
                        Slider(value: $s.gateDB, in: -90...(-20), step: 1)
                    }
                    LabeledContent(String(format: tr("Громкость: %.0f%%"), s.gain * 100)) {
                        Slider(value: $s.gain, in: 0...2)
                    }
                    if let idx = s.currentVoice?.index {
                        LabeledContent(String(format: "Index: %.2f", s.indexRatio)) {
                            Slider(value: $s.indexRatio, in: 0...1)
                        }
                        .help(trf("Доля признаков из индекса (%@ векторов). Больше — ближе к голосу модели, но может «смазывать» дикцию.", "\(idx.count)"))
                        LabeledContent(String(format: "Protect: %.2f", s.protect)) {
                            Slider(value: $s.protect, in: 0...0.5)
                        }
                        .help(tr("Защита глухих согласных и дыхания. 0.5 — выключено."))
                    } else if s.currentVoice != nil {
                        Text(tr("У голоса нет index — кнопка «Index…» подключит его."))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Toggle(tr("Без обработки (bypass)"), isOn: $s.bypass)
                        Spacer()
                        Toggle("Mute", isOn: $s.muted)
                        Toggle("Push-to-talk", isOn: $s.pushToTalk)
                            .help(tr("Звук идёт, только пока зажата клавиша push-to-talk (Настройки → Горячие клавиши)"))
                    }
                }
            }
            .formStyle(.grouped)

            statusBar
        }
        .alert(tr("Новый профиль"), isPresented: $ui.askProfileName) {
            TextField(tr("Название"), text: $ui.newProfileName)
            Button(tr("Сохранить")) { s.saveProfile(named: ui.newProfileName) }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Сохраняет голос, задержку, вычисления и параметры звука."))
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StateBadge(text: s.running ? tr("МИКРОФОН") : tr("ОСТАНОВЛЕНО"), color: s.running ? .green : .secondary)
                if s.running {
                    if s.bypass {
                        StateBadge(text: "BYPASS", color: .orange)
                    } else {
                        StateBadge(text: tr("ОБРАБОТКА"), color: .blue)
                    }
                    if s.effectiveMuted { StateBadge(text: s.pushToTalk && !s.muted ? "PTT" : "MUTE", color: .red) }
                }
                if let p = s.activeProfile { StateBadge(text: p.name, color: .purple) }
                if s.lastError != nil { StateBadge(text: tr("ОШИБКА"), color: .red) }
                Spacer()
                Button { openWindow(id: "diagnostics") } label: { Label(tr("Диагностика"), systemImage: "gauge.with.dots.needle.33percent") }
                    .controlSize(.small)
            }
            HStack(spacing: 12) {
                Button(action: { s.toggle() }) {
                    Label(s.running ? tr("Стоп") : tr("Старт"), systemImage: s.running ? "stop.fill" : "play.fill")
                        .frame(width: 90)
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(s.running ? .red : .accentColor)
                .disabled(s.busy || s.benchRunning || (!s.running && s.currentConfig == nil))

                if s.setupRunning {
                    if let f = s.setupProgress {
                        ProgressView(value: f).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if s.busy {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.setupRunning ? s.setupPhase : s.status).lineLimit(1)
                    if s.running {
                        let load = s.stats.blockMs > 0 ? s.stats.processMs / s.stats.blockMs : 0
                        Text(liveLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(load < 0.7 ? Color.green : (load < 1 ? Color.orange : Color.red))
                    }
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(s.log.isEmpty ? tr("Лог пуст") : s.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logEnd")
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .onChange(of: s.log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
        }
        .padding(12)
    }

    private var liveLine: String {
        var parts = [String(format: tr("обработка %.0f из %.0f мс"), s.stats.processMs, s.stats.blockMs)]
        if s.stats.endToEnd.count > 0 { parts.append(String(format: tr("задержка ≈%.0f мс"), s.stats.endToEnd.p50)) }
        parts.append(String(format: tr("вход %.0f дБ"), s.stats.inputDB))
        if s.stats.gated { parts.append(tr("тишина")) }
        if s.stats.counters.underrunEvents > 0 { parts.append("underrun \(s.stats.counters.underrunEvents)") }
        return parts.joined(separator: " · ")
    }
}

struct StateBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var s: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(s.running ? trf("Работает: %@", "\(s.selectedVoice)") : tr("Остановлено"))
        if s.running, s.stats.endToEnd.count > 0 {
            Text(String(format: tr("Задержка ≈%.0f мс · обработка %.0f мс"), s.stats.endToEnd.p50, s.stats.processMs))
        }
        Divider()
        Button(s.running ? tr("Стоп") : tr("Старт")) { s.toggle() }
            .disabled(s.busy || s.benchRunning || (!s.running && s.currentConfig == nil))
        Toggle("Mute", isOn: $s.muted)
        Toggle(tr("Без обработки"), isOn: $s.bypass)
        Toggle("Push-to-talk", isOn: $s.pushToTalk)
        if !s.profiles.isEmpty {
            Divider()
            ForEach(s.profiles) { p in
                Button((p.id == s.activeProfileID ? "✓ " : "   ") + p.name) { s.applyProfile(p) }
            }
        }
        Divider()
        Button(tr("Открыть RVCMac")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(tr("Диагностика")) { openWindow(id: "diagnostics"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(tr("Выйти")) { s.stop(); NSApp.terminate(nil) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        Form {
            Section(tr("Горячие клавиши (работают глобально)")) {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            HotkeyRecorder(hotkey: Binding(get: { s.hotkeys[action] }, set: { s.hotkeys[action] = $0 }))
                            if s.hotkeyFailures.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help(tr("Сочетание занято другим приложением"))
                            }
                        }
                    }
                }
                Button(tr("Сбросить по умолчанию")) { s.resetHotkeys() }
                Text(tr("Нажми на поле и затем сочетание. Нужен хотя бы один модификатор (⌘⌥⌃⇧), кроме F-клавиш. ⌫ — очистить, ⎋ — отмена."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("Язык")) {
                Picker(tr("Язык интерфейса"), selection: $s.language) {
                    Text(tr("Как в системе")).tag(AppLanguage.system)
                    Text(verbatim: "Русский").tag(AppLanguage.ru)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
                Text(tr("Окна и настройки переключаются сразу, меню приложения — после перезапуска."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("Конвертер моделей")) {
                LabeledContent(tr("Состояние")) {
                    Text(s.setupRunning ? s.setupPhase : (s.converterReady ? tr("установлен") : tr("не установлен — поставится при первом импорте")))
                }
                LabeledContent(tr("Папка данных")) {
                    Text(RVCMacPaths.home.path).textSelection(.enabled).font(.caption.monospaced())
                }
                HStack {
                    if s.converterReady {
                        Button(tr("Переустановить")) { s.reinstallConverter() }.disabled(s.setupRunning || s.busy)
                    } else {
                        Button(tr("Установить сейчас")) { s.installConverter() }.disabled(s.setupRunning || s.busy)
                    }
                    Button(tr("Открыть папку данных")) { s.revealDataFolder() }
                }
            }
            Section(tr("Окно")) {
                Toggle(tr("Оставаться в строке меню после закрытия окна"), isOn: $s.keepInMenuBar)
            }
            Section(tr("Отчёты и приватность")) {
                Toggle(tr("Не сохранять в отчётах имена устройств и пути к файлам"), isOn: $s.anonymizeReports)
                Text(tr("Аудио обрабатывается только локально. В лог и отчёты звук не пишется; WAV сохраняется лишь по флажку в бенчмарке."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
    }
}

/// Click, then press a shortcut. Uses a local key monitor, so it needs no extra permissions.
final class HotkeyRecorderModel: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func begin(onKey: @escaping (NSEvent) -> Bool) {
        stop()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if onKey(event) { self?.stop() }
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @StateObject private var model = HotkeyRecorderModel()

    var body: some View {
        Button(model.recording ? tr("Нажми сочетание…") : (hotkey?.display ?? tr("не задано"))) {
            if model.recording {
                model.stop()
            } else {
                let binding = $hotkey
                // returns true when recording is finished
                model.begin { event in
                    switch Int(event.keyCode) {
                    case 53: return true                               // escape
                    case 51, 117: binding.wrappedValue = nil; return true  // delete / forward delete
                    default:
                        if let hk = Hotkey(event: event) {
                            binding.wrappedValue = hk
                            return true
                        }
                        NSSound.beep()
                        return false
                    }
                }
            }
        }
        .frame(minWidth: 150)
        .onDisappear { model.stop() }
    }
}
