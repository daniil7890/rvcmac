import Charts
import RVCMacCore
import SwiftUI

// View-local state lives in small ObservableObjects instead of @State: in recent SDKs @State is a
// macro whose plugin ships only with Xcode, and the app must build with Command Line Tools alone.
final class DiagnosticsUI: ObservableObject {
    @Published var tab = 0
}

final class CompareModel: ObservableObject {
    @Published var a: URL? { didSet { load() } }
    @Published var b: URL? { didSet { load() } }
    @Published var ra: Report?
    @Published var rb: Report?
    @Published var error: String?

    func load() {
        error = nil
        do {
            ra = try a.map { try ReportStore.load($0) }
            rb = try b.map { try ReportStore.load($0) }
        } catch {
            self.error = trf("Не удалось прочитать отчёт: %@", "\(error.localizedDescription)")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var s: AppState
    @StateObject private var ui = DiagnosticsUI()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ui.tab) {
                Text("Live").tag(0)
                Text(tr("Бенчмарк")).tag(1)
                Text(tr("Сравнение")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch ui.tab {
            case 0: LivePanel()
            case 1: BenchmarkPanel()
            default: ComparePanel()
            }
        }
    }
}

private func ms(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "—" }

// MARK: - Live

private struct LivePanel: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !s.running {
                    Text(tr("Запусти обработку, чтобы увидеть метрики. Отчёт последней сессии можно сохранить и после остановки."))
                        .foregroundStyle(.secondary)
                }
                latencyBox
                chartBox
                stagesBox
                countersBox
                HStack {
                    Button(tr("Сохранить отчёт сессии (JSON + CSV)")) { s.exportSessionReport() }
                        .disabled(!s.canExportSession)
                    Button(tr("Открыть папку отчётов")) { s.revealReports() }
                }
            }
            .padding(16)
        }
    }

    private var latencyBox: some View {
        GroupBox(tr("Задержка (последние 64 блока)")) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("p50").bold(); Text("p95").bold(); Text("p99").bold(); Text(tr("макс")).bold()
                }
                row(tr("Полная (оценка)"), s.stats.endToEnd)
                row(tr("Конвейер: захват → вывод"), s.stats.pipeline)
                GridRow {
                    Text(tr("Алгоритмическая (блок + кроссфейд + SOLA)"))
                    Text(ms(s.stats.algorithmicMs)); Text(""); Text(""); Text("")
                }
                GridRow {
                    Text(tr("Устройства (Core Audio: вход / выход)"))
                    Text(ms(s.stats.deviceInputMs)); Text(ms(s.stats.deviceOutputMs)); Text(""); Text("")
                }
                GridRow {
                    Text(tr("Очередь вывода сейчас"))
                    Text(ms(s.stats.outputQueueMs)); Text(""); Text(""); Text("")
                }
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            Text(trf("Полная = конвейер + алгоритмическая + устройства. Буферы IO: вход %@, выход %@ кадров.", "\(s.stats.inputBufferFrames)", "\(s.stats.outputBufferFrames)"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ d: Distribution) -> some View {
        GridRow {
            Text(title)
            Text(d.count > 0 ? ms(d.p50) : "—")
            Text(d.count > 0 ? ms(d.p95) : "—")
            Text(d.count > 0 ? ms(d.p99) : "—")
            Text(d.count > 0 ? ms(d.max) : "—")
        }
    }

    private var chartBox: some View {
        GroupBox(tr("Задержка и обработка во времени, мс")) {
            Chart {
                ForEach(s.chart) { p in
                    if p.endToEnd.isFinite {
                        LineMark(x: .value("t", p.t), y: .value(tr("мс"), p.endToEnd), series: .value(tr("ряд"), tr("Полная p50")))
                            .foregroundStyle(by: .value(tr("ряд"), tr("Полная p50")))
                    }
                    LineMark(x: .value("t", p.t), y: .value(tr("мс"), p.processMs), series: .value(tr("ряд"), tr("Обработка (макс)")))
                        .foregroundStyle(by: .value(tr("ряд"), tr("Обработка (макс)")))
                }
                if s.stats.blockMs > 0 {
                    RuleMark(y: .value(tr("блок"), s.stats.blockMs))
                        .foregroundStyle(.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXAxisLabel(tr("секунды"))
            .frame(height: 180)
            .padding(4)
        }
    }

    private var stagesBox: some View {
        GroupBox(tr("Этапы обработки блока (только блоки с инференсом), мс")) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow { Text(""); Text("p50").bold(); Text("p95").bold() }
                ForEach(Stage.allCases, id: \.rawValue) { st in
                    GridRow {
                        Text(st.title)
                        Text(ms(s.stats.stageP50[st.rawValue]))
                        Text(ms(s.stats.stageP95[st.rawValue]))
                    }
                }
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var countersBox: some View {
        GroupBox(tr("Стабильность и ресурсы")) {
            let c = s.stats.counters
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow { Text(tr("Блоков")); Text("\(c.blocks)") }
                GridRow { Text(tr("Underrun вывода (события / кадры)")); Text("\(c.underrunEvents) / \(c.underrunFrames)") }
                GridRow { Text(tr("Переполнение входа (кадры)")); Text("\(c.inputOverflowFrames)") }
                GridRow { Text(tr("Пропущено входа, чтобы догнать")); Text(String(format: tr("%.0f мс"), c.skippedInputMs)) }
                GridRow { Text(tr("Обрезано вывода (кадры)")); Text("\(c.outputTrimFrames)") }
                GridRow { Text(tr("Перегрузки IO (HAL overload)")); Text("\(s.stats.overloads)") }
                GridRow { Text(tr("Смен голоса")); Text("\(c.modelSwitches)") }
                Divider()
                GridRow { Text(tr("CPU процесса")); Text(String(format: tr("%.0f%% ядра"), s.resources.cpuPercent)) }
                GridRow { Text(tr("Память")); Text(String(format: tr("%.0f МБ"), s.resources.memoryMB)) }
                GridRow { Text(tr("Тепловое состояние")); Text(s.resources.thermal) }
                GridRow { Text("GPU / Neural Engine"); Text(tr("нет публичного API — см. Instruments")).foregroundStyle(.secondary) }
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - Benchmark

private struct BenchmarkPanel: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(tr("Параметры")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(trf("Вход: %@", s.benchFile?.lastPathComponent ?? tr("синтетический голосоподобный сигнал, 20 с")))
                                .lineLimit(1)
                            Spacer()
                            Button(tr("Выбрать файл…")) { s.chooseBenchmarkFile() }
                            if s.benchFile != nil { Button(tr("Сбросить")) { s.benchFile = nil } }
                        }
                        Stepper(trf("Прогонов: %@", "\(s.benchRuns)"), value: $s.benchRuns, in: 1...10)
                        Toggle(tr("Подавать блоки в реальном темпе (как live)"), isOn: $s.benchPacing)
                        Toggle(tr("Сохранить результат первого прогона в WAV"), isOn: $s.benchSaveAudio)
                        Text(tr("Голос, задержка, вычисления и параметры звука берутся из главного окна. Порог тишины в тесте отключён. Холодный старт (загрузка моделей и первый блок) измеряется отдельно, затем прогрев 10 блоков."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
                HStack {
                    if s.benchRunning {
                        Button(tr("Остановить")) { s.cancelBenchmark() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button(tr("Запустить бенчмарк")) { s.runBenchmark() }
                            .buttonStyle(.borderedProminent)
                            .disabled(s.running || s.currentConfig == nil)
                    }
                    Text(s.benchProgress).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Открыть папку отчётов")) { s.revealReports() }
                }
                if let r = s.lastReport { ReportSummaryView(report: r) }
            }
            .padding(16)
        }
    }
}

struct ReportSummaryView: View {
    let report: Report

    var body: some View {
        GroupBox(trf("%@: %@ · блок %@ мс · %@", report.kind == .live ? tr("Сессия") : tr("Бенчмарк"), "\(report.model.name)", "\(report.config.blockMs)", "\(report.config.compute)")) {
            VStack(alignment: .leading, spacing: 8) {
                if let c = report.coldStart {
                    Text(trf("Холодный старт: загрузка %@ мс, первый блок %@ мс", "\(ms(c.loadMs))", "\(ms(c.firstBlockMs))"))
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { Text(""); Text("p50").bold(); Text("p95").bold(); Text("p99").bold(); Text(tr("макс")).bold() }
                    ForEach(Stage.allCases, id: \.rawValue) { st in
                        if let d = report.stages[st.key], d.count > 0 {
                            GridRow { Text(st.title); Text(ms(d.p50)); Text(ms(d.p95)); Text(ms(d.p99)); Text(ms(d.max)) }
                        }
                    }
                    if let l = report.latency, l.endToEnd.count > 0 {
                        GridRow {
                            Text(report.kind == .live ? tr("Полная задержка") : tr("Обработка + алгоритмическая")).bold()
                            Text(ms(l.endToEnd.p50)); Text(ms(l.endToEnd.p95)); Text(ms(l.endToEnd.p99)); Text(ms(l.endToEnd.max))
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                ForEach(report.runs, id: \.index) { r in
                    Text(String(format: tr("Прогон %d: %d блоков, RTF %.2f, блок p95 %.1f мс"), r.index, r.blocks, r.realTimeFactor,
                                r.stages[Stage.total.key]?.p95 ?? .nan))
                        .font(.caption.monospacedDigit())
                }
                Text(trf("Underrun: %@ · тепло: %@ → %@ · %@, macOS %@", "\(report.counters.underrunEvents)", "\(report.system.thermalStart)", "\(report.system.thermalEnd)", "\(report.system.machine)", "\(report.system.macOS)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - Compare

private struct ComparePanel: View {
    @EnvironmentObject var s: AppState
    @StateObject private var m = CompareModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                picker(tr("A (до)"), $m.a)
                picker(tr("B (после)"), $m.b)
                Button { s.refreshReports() } label: { Image(systemName: "arrow.clockwise") }
            }
            if let error = m.error { Text(error).foregroundStyle(.red) }
            if let ra = m.ra, let rb = m.rb {
                let diffs = ReportComparison.configDifferences(ra, rb)
                if !diffs.isEmpty {
                    Text(tr("Конфигурации различаются — сравнение не на одном стенде: ") + diffs.joined(separator: "; "))
                        .foregroundStyle(.orange).font(.caption)
                }
                Table(ReportComparison.rows(ra, rb)) {
                    TableColumn(tr("Метрика")) { Text($0.metric) }
                    TableColumn("A") { Text(ms($0.a)).monospacedDigit() }
                    TableColumn("B") { Text(ms($0.b)).monospacedDigit() }
                    TableColumn("Δ") { r in
                        Text(String(format: "%+.1f (%+.0f%%)", r.delta, r.deltaPercent))
                            .monospacedDigit()
                            .foregroundStyle(r.delta < 0 ? .green : (r.delta > 0 ? .red : .primary))
                    }
                }
            } else {
                Text(tr("Выбери два отчёта. Меньше — лучше для всех метрик в таблице.")).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .onAppear { s.refreshReports() }
    }

    private func picker(_ title: String, _ sel: Binding<URL?>) -> some View {
        Picker(title, selection: sel) {
            Text("—").tag(URL?.none)
            ForEach(s.reportFiles, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag(URL?.some($0)) }
        }
    }
}
