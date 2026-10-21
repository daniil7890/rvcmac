import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RVCMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("RVCMac") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 560, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: AppState

    private let blockOptions = [100, 150, 200, 250, 300, 350, 400, 500]
    private let extraOptions = [200, 300, 500, 750, 1000]
    private let crossfadeOptions = [50, 100, 150, 200]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Голос") {
                    HStack {
                        Picker("Модель", selection: $s.selectedVoice) {
                            if s.voices.isEmpty { Text("— нет моделей —").tag("") }
                            ForEach(s.voices, id: \.name) { v in
                                Text("\(v.name)  ·  \(v.version) · \(v.sr / 1000) кГц").tag(v.name)
                            }
                        }
                        Button("Импорт…") { s.importModel() }
                        Button("Index…") { s.addIndex() }
                            .disabled(s.currentVoice == nil)
                            .help("Подключить .index к выбранному голосу")
                        Button { s.refreshVoices() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Обновить список")
                    }
                    .disabled(s.busy || s.running)
                }

                Section("Задержка") {
                    HStack {
                        Picker("Блок", selection: $s.blockMs) {
                            ForEach(blockOptions, id: \.self) { Text("\($0) мс").tag($0) }
                        }
                        Picker("Контекст", selection: $s.extraMs) {
                            ForEach(extraOptions, id: \.self) { Text("\($0) мс").tag($0) }
                        }
                        Picker("Кроссфейд", selection: $s.crossfadeMs) {
                            ForEach(crossfadeOptions, id: \.self) { Text("\($0) мс").tag($0) }
                        }
                    }
                    .disabled(s.busy || s.running)
                    if s.currentVoice != nil && s.currentConfig == nil {
                        HStack {
                            Text("Под эти настройки модель ещё не собрана (или собрана старой версией).")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Собрать") { s.convertCurrentConfig() }.disabled(s.busy)
                        }
                    }
                    Picker("Вычисления", selection: $s.compute) {
                        ForEach(ComputeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(s.busy || s.running)
                }

                Section("Аудио") {
                    HStack {
                        Picker("Вход", selection: $s.inputUID) {
                            ForEach(s.inputs) { Text($0.name).tag($0.uid) }
                        }
                        Button { s.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Обновить устройства")
                    }
                    Picker("Выход", selection: $s.outputUID) {
                        ForEach(s.outputs) { Text($0.name).tag($0.uid) }
                    }
                }
                .disabled(s.busy || s.running)

                Section("Звук") {
                    LabeledContent("Тон: \(Int(s.pitch.rounded())) пт") {
                        Slider(value: $s.pitch, in: -24...24, step: 1)
                    }
                    LabeledContent("Порог тишины: \(Int(s.gateDB)) дБ") {
                        Slider(value: $s.gateDB, in: -90...(-20), step: 1)
                    }
                    LabeledContent(String(format: "Громкость: %.0f%%", s.gain * 100)) {
                        Slider(value: $s.gain, in: 0...2)
                    }
                    if let idx = s.currentVoice?.index {
                        LabeledContent(String(format: "Index: %.2f", s.indexRatio)) {
                            Slider(value: $s.indexRatio, in: 0...1)
                        }
                        .help("Доля признаков из индекса (\(idx.count) векторов). Больше — ближе к голосу модели, но может «смазывать» дикцию.")
                        LabeledContent(String(format: "Protect: %.2f", s.protect)) {
                            Slider(value: $s.protect, in: 0...0.5)
                        }
                        .help("Защита глухих согласных и дыхания. 0.5 — выключено.")
                    } else if s.currentVoice != nil {
                        Text("У голоса нет index — кнопка «Index…» подключит его.")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Без обработки (проверка маршрута звука)", isOn: $s.bypass)
                }
            }
            .formStyle(.grouped)

            statusBar
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { s.toggle() }) {
                    Label(s.running ? "Стоп" : "Старт", systemImage: s.running ? "stop.fill" : "play.fill")
                        .frame(width: 90)
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(s.running ? .red : .accentColor)
                .disabled(s.busy || (!s.running && s.currentConfig == nil))

                if s.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.status).lineLimit(1)
                    if s.running {
                        let load = s.stats.blockMs > 0 ? s.stats.processMs / s.stats.blockMs : 0
                        Text(String(format: "обработка %.0f мс из %.0f мс · вход %.0f дБ%@",
                                    s.stats.processMs, s.stats.blockMs, s.stats.inputDB, s.stats.gated ? " · тишина" : ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(load < 0.7 ? Color.green : (load < 1 ? Color.orange : Color.red))
                    }
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(s.log.isEmpty ? "Лог пуст" : s.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logEnd")
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .onChange(of: s.log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
        }
        .padding(12)
    }
}
