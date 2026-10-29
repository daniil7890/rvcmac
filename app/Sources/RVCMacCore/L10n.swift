import Foundation

/// Interface language chosen in Settings.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, ru, en
}

/// Minimal in-app localization: Russian source strings are the keys, English lives in `english`.
///
/// Chosen over .strings/.xcstrings so the language can be switched live and the app still builds with
/// Command Line Tools only. Every `tr`/`trf` literal must have an entry here; a unit test checks that,
/// matching format specifiers, and that no Cyrillic literal in the sources bypasses `tr`.
public enum Loc {
    public enum Language: Sendable { case ru, en }

    public static let defaultsKey = "appLanguage"

    public static var language: Language = resolve(
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system)

    public static func resolve(_ choice: AppLanguage) -> Language {
        switch choice {
        case .ru: return .ru
        case .en: return .en
        case .system:
            let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return first.hasPrefix("ru") ? .ru : .en
        }
    }

    public static func tr(_ s: String) -> String {
        language == .en ? (english[s] ?? s) : s
    }

    public static let english: [String: String] = [
        "Остановлено":
            "Stopped",
        "Дождись окончания бенчмарка.":
            "Wait for the benchmark to finish.",
        "Нет выбранного голоса — импортируй модель.":
            "No voice selected — import a model.",
        "Для этих настроек задержки модель ещё не сконвертирована.":
            "The model has not been built for these latency settings yet.",
        "Выбери устройства ввода и вывода.":
            "Choose input and output devices.",
        "Вход и выход — одно виртуальное устройство (%@): звук пойдёт по кругу. Выбери физический микрофон.":
            "Input and output are the same virtual device (%@): audio would loop back. Choose a physical microphone.",
        "Загрузка моделей (первый раз Neural Engine компилирует их до минуты)…":
            "Loading models (the first time the Neural Engine may take up to a minute to compile them)…",
        "Нет доступа к микрофону":
            "No microphone access",
        "Разреши микрофон: Системные настройки → Конфиденциальность → Микрофон → RVCMac.":
            "Allow the microphone: System Settings → Privacy & Security → Microphone → RVCMac.",
        "Прогрев моделей…":
            "Warming up models…",
        "Голос переключён на %@ за %.0f мс (с ожиданием границы блока).":
            "Switched voice to %@ in %.0f ms (including the wait for a block boundary).",
        "Работает: %@ · %@ → %@":
            "Running: %@ · %@ → %@",
        "Модели загружены за %.1f с (%@), прогрев %.0f мс. Устройства: вход %.1f мс, выход %.1f мс по данным Core Audio.":
            "Models loaded in %.1f s (%@), warm-up %.0f ms. Devices: input %.1f ms, output %.1f ms as reported by Core Audio.",
        "Ошибка запуска аудио":
            "Audio start failed",
        "Аудио: %@":
            "Audio: %@",
        "Ошибка загрузки модели":
            "Model loading failed",
        "Модель: %@":
            "Model: %@",
        "Остановлено из-за ошибки":
            "Stopped because of an error",
        "Устройство «%@» отключилось. Обработка остановлена.":
            "Device “%@” was disconnected. Processing stopped.",
        "У «%@» сменилась частота дискретизации — перезапускаю аудио.":
            "The sample rate of “%@” changed — restarting audio.",
        "У «%@» нет сборки %@ — переключение на лету невозможно. Останови и нажми «Собрать».":
            "“%@” has no %@ build — cannot switch live. Stop and press “Build”.",
        "Готовлю голос %@…":
            "Preparing voice %@…",
        "Переключение голоса: %@":
            "Voice switch: %@",
        "Профили: %@":
            "Profiles: %@",
        "В профиле «%@» голос %@, но его нет в библиотеке.":
            "Profile “%@” uses voice %@, which is not in the library.",
        "Профиль «%@» меняет задержку или вычисления — перезапуск.":
            "Profile “%@” changes latency or compute units — restarting.",
        "Не удалось назначить: ":
            "Could not assign: ",
        " (сочетание занято).":
            " (shortcut is taken).",
        "Полная задержка = конвейер (захват последнего сэмпла блока → воспроизведение первого сэмпла результата) + алгоритмическая (блок + кроссфейд + SOLA − смещение) + задержки устройств по данным Core Audio.":
            "Total latency = pipeline (capture of a block's last sample → playback of its first output sample) + algorithmic (block + crossfade + SOLA − offset) + device latency as reported by Core Audio.",
        "Задержка ресемплера AVAudioConverter (единицы мс) не учитывается.":
            "The AVAudioConverter resampler delay (a few ms) is not included.",
        "Голос переключался во время сессии: %@ раз.":
            "The voice was switched %@ time(s) during the session.",
        "Сессия: %@ блоков":
            "Session: %@ blocks",
        ", задержка p50 %.0f / p95 %.0f / p99 %.0f мс":
            ", latency p50 %.0f / p95 %.0f / p99 %.0f ms",
        ", обработка блока p95 %.0f мс":
            ", block processing p95 %.0f ms",
        "Нет данных сессии — запусти обработку.":
            "No session data — start processing first.",
        "Отчёт сохранён: %@ (+ .csv)":
            "Report saved: %@ (+ .csv)",
        "Отчёт: %@":
            "Report: %@",
        "Аудиофайл для бенчмарка (wav, aiff, m4a, mp3…)":
            "Audio file for the benchmark (wav, aiff, m4a, mp3…)",
        "Останови обработку: бенчмарк и live-режим делят Neural Engine.":
            "Stop processing first: the benchmark and live mode share the Neural Engine.",
        "Выбери голос с собранной конфигурацией.":
            "Choose a voice that is built for these settings.",
        "Старт…":
            "Starting…",
        "Бенчмарк: %@, %@, %@, прогонов %@, %@.":
            "Benchmark: %@, %@, %@, %@ runs, %@.",
        "синтетический сигнал":
            "synthetic signal",
        "Готово":
            "Done",
        "Бенчмарк: %@":
            "Benchmark: %@",
        "Бенчмарк готов":
            "Benchmark finished",
        ": загрузка %.0f мс, первый блок %.0f мс":
            ": load %.0f ms, first block %.0f ms",
        "; блок p50 %.1f / p95 %.1f / p99 %.1f мс":
            "; block p50 %.1f / p95 %.1f / p99 %.1f ms",
        "Выбери RVC-модель (.pth или .safetensors)":
            "Choose an RVC model (.pth or .safetensors)",
        "Нужен файл .pth или .safetensors":
            "A .pth or .safetensors file is required",
        "Выбери .index для голоса %@ (added_*.index)":
            "Choose the .index for voice %@ (added_*.index)",
        "Нужен файл .index":
            "An .index file is required",
        "Конвертация модели…":
            "Converting model…",
        "Конвертация завершена":
            "Conversion finished",
        "Конвертация упала (код %@) — см. лог":
            "Conversion failed (code %@) — see the log",
        "Не удалось запустить конвертер: %@":
            "Could not start the converter: %@",
        "Модель не прошла безопасную загрузку":
            "The model failed safe loading",
        "Файл .pth содержит не только веса. Полная загрузка pickle может выполнить код из файла. Продолжай, только если доверяешь источнику модели. Лучше найти версию .safetensors.":
            "This .pth file contains more than plain weights. Full pickle loading can execute code from the file. Continue only if you trust where the model came from. A .safetensors version is safer.",
        "Отмена":
            "Cancel",
        "Доверяю, загрузить":
            "I trust it, load",
        "вход":
            "input",
        "выход":
            "output",
        "нет публичного API для нагрузки GPU/ANE процесса; смотри Instruments → Core ML / Metal System Trace":
            "no public API for per-process GPU/ANE load; use Instruments → Core ML / Metal System Trace",
        "Аудиофайл слишком короткий для этого размера блока":
            "The audio file is too short for this block size",
        "Бенчмарк остановлен":
            "Benchmark stopped",
        "Загрузка моделей…":
            "Loading models…",
        "Холодный старт: первый блок…":
            "Cold start: first block…",
        "Прогрев…":
            "Warming up…",
        "Прогон %@/%@: блок %@/%@":
            "Run %@/%@: block %@/%@",
        "Файловый тест: задержка = алгоритмическая + обработка, без устройств и очередей.":
            "File test: latency = algorithmic + processing, without devices and queues.",
        "Порог тишины отключён, чтобы каждый блок проходил через модели.":
            "The silence gate is off so every block goes through the models.",
        "Загрузка моделей включает компиляцию .mlmodelc только если кэш устарел; кэш Neural Engine у macOS свой.":
            "Model loading includes .mlmodelc compilation only when the cache is stale; macOS keeps its own Neural Engine cache.",
        "Не удалось прочитать отчёт: %@":
            "Could not read the report: %@",
        "Бенчмарк":
            "Benchmark",
        "Сравнение":
            "Compare",
        "Запусти обработку, чтобы увидеть метрики. Отчёт последней сессии можно сохранить и после остановки.":
            "Start processing to see metrics. The last session's report can still be saved after stopping.",
        "Сохранить отчёт сессии (JSON + CSV)":
            "Save session report (JSON + CSV)",
        "Открыть папку отчётов":
            "Open reports folder",
        "Задержка (последние 64 блока)":
            "Latency (last 64 blocks)",
        "макс":
            "max",
        "Полная (оценка)":
            "Total (estimate)",
        "Конвейер: захват → вывод":
            "Pipeline: capture → playback",
        "Алгоритмическая (блок + кроссфейд + SOLA)":
            "Algorithmic (block + crossfade + SOLA)",
        "Устройства (Core Audio: вход / выход)":
            "Devices (Core Audio: input / output)",
        "Очередь вывода сейчас":
            "Output queue now",
        "Полная = конвейер + алгоритмическая + устройства. Буферы IO: вход %@, выход %@ кадров.":
            "Total = pipeline + algorithmic + devices. IO buffers: input %@, output %@ frames.",
        "Задержка и обработка во времени, мс":
            "Latency and processing over time, ms",
        "мс":
            "ms",
        "ряд":
            "series",
        "Полная p50":
            "Total p50",
        "Обработка (макс)":
            "Processing (max)",
        "блок":
            "block",
        "секунды":
            "seconds",
        "Этапы обработки блока (только блоки с инференсом), мс":
            "Block processing stages (inferred blocks only), ms",
        "Стабильность и ресурсы":
            "Stability and resources",
        "Блоков":
            "Blocks",
        "Underrun вывода (события / кадры)":
            "Output underruns (events / frames)",
        "Переполнение входа (кадры)":
            "Input overflow (frames)",
        "Пропущено входа, чтобы догнать":
            "Input skipped to catch up",
        "%.0f мс":
            "%.0f ms",
        "Обрезано вывода (кадры)":
            "Output trimmed (frames)",
        "Перегрузки IO (HAL overload)":
            "IO overloads (HAL)",
        "Смен голоса":
            "Voice switches",
        "CPU процесса":
            "Process CPU",
        "%.0f%% ядра":
            "%.0f%% of a core",
        "Память":
            "Memory",
        "%.0f МБ":
            "%.0f MB",
        "Тепловое состояние":
            "Thermal state",
        "нет публичного API — см. Instruments":
            "no public API — see Instruments",
        "Параметры":
            "Parameters",
        "Вход: %@":
            "Input: %@",
        "синтетический голосоподобный сигнал, 20 с":
            "synthetic voice-like signal, 20 s",
        "Выбрать файл…":
            "Choose file…",
        "Сбросить":
            "Reset",
        "Прогонов: %@":
            "Runs: %@",
        "Подавать блоки в реальном темпе (как live)":
            "Feed blocks in real time (like live)",
        "Сохранить результат первого прогона в WAV":
            "Save the first run's output as WAV",
        "Голос, задержка, вычисления и параметры звука берутся из главного окна. Порог тишины в тесте отключён. Холодный старт (загрузка моделей и первый блок) измеряется отдельно, затем прогрев 10 блоков.":
            "Voice, latency, compute units and sound parameters come from the main window. The silence gate is off during the test. Cold start (model loading and the first block) is measured separately, followed by a 10-block warm-up.",
        "Остановить":
            "Stop",
        "Запустить бенчмарк":
            "Run benchmark",
        "%@: %@ · блок %@ мс · %@":
            "%@: %@ · block %@ ms · %@",
        "Сессия":
            "Session",
        "Холодный старт: загрузка %@ мс, первый блок %@ мс":
            "Cold start: load %@ ms, first block %@ ms",
        "Полная задержка":
            "Total latency",
        "Обработка + алгоритмическая":
            "Processing + algorithmic",
        "Прогон %d: %d блоков, RTF %.2f, блок p95 %.1f мс":
            "Run %d: %d blocks, RTF %.2f, block p95 %.1f ms",
        "Underrun: %@ · тепло: %@ → %@ · %@, macOS %@":
            "Underruns: %@ · thermal: %@ → %@ · %@, macOS %@",
        "A (до)":
            "A (before)",
        "B (после)":
            "B (after)",
        "Конфигурации различаются — сравнение не на одном стенде: ":
            "Configurations differ — not a like-for-like comparison: ",
        "Метрика":
            "Metric",
        "Выбери два отчёта. Меньше — лучше для всех метрик в таблице.":
            "Choose two reports. Lower is better for every metric in the table.",
        "Старт / стоп":
            "Start / stop",
        "Без обработки (bypass)":
            "Bypass processing",
        "Push-to-talk (удерживать)":
            "Push-to-talk (hold)",
        "Следующий профиль":
            "Next profile",
        "нет собранных настроек задержки":
            "no latency settings built",
        "%@: нет %@":
            "%@: missing %@",
        "%@: нет общей модели %@/%@":
            "%@: missing shared model %@/%@",
        "нет файла индекса %@":
            "index file %@ is missing",
        "размер %@ не совпадает с voice.json":
            "size of %@ does not match voice.json",
        "неожиданная размерность признаков %@":
            "unexpected feature size %@",
        "Диагностика":
            "Diagnostics",
        "Профиль":
            "Profile",
        "— без профиля —":
            "— no profile —",
        "Сохранить":
            "Save",
        "Записать текущие настройки в выбранный профиль":
            "Write the current settings to the selected profile",
        "Новый…":
            "New…",
        "Удалить профиль":
            "Delete profile",
        "Голос":
            "Voice",
        "Модель":
            "Model",
        "— нет моделей —":
            "— no models —",
        "%@%@  ·  %@ · %@ кГц":
            "%@%@  ·  %@ · %@ kHz",
        "Смена голоса на лету: новый голос готовится в фоне и подмешивается кроссфейдом":
            "Live voice switch: the new voice is prepared in the background and crossfaded in",
        "Импорт…":
            "Import…",
        "Подключить .index к выбранному голосу":
            "Attach an .index to the selected voice",
        "Обновить список":
            "Refresh list",
        "Проблемы модели: ":
            "Model problems: ",
        "Задержка":
            "Latency",
        "Блок":
            "Block",
        "%@ мс":
            "%@ ms",
        "Контекст":
            "Context",
        "Кроссфейд":
            "Crossfade",
        "Под эти настройки модель ещё не собрана (или собрана старой версией).":
            "The model is not built for these settings yet (or was built by an older version).",
        "Собрать":
            "Build",
        "Вычисления":
            "Compute",
        "Аудио":
            "Audio",
        "Вход":
            "Input",
        "Обновить устройства":
            "Refresh devices",
        "Выход":
            "Output",
        "Звук":
            "Sound",
        "Тон: %@ пт":
            "Pitch: %@ st",
        "Порог тишины: %@ дБ":
            "Silence gate: %@ dB",
        "Громкость: %.0f%%":
            "Volume: %.0f%%",
        "Доля признаков из индекса (%@ векторов). Больше — ближе к голосу модели, но может «смазывать» дикцию.":
            "Share of features taken from the index (%@ vectors). Higher sounds closer to the model's voice but can blur articulation.",
        "Защита глухих согласных и дыхания. 0.5 — выключено.":
            "Protects voiceless consonants and breaths. 0.5 = off.",
        "У голоса нет index — кнопка «Index…» подключит его.":
            "This voice has no index — use “Index…” to attach one.",
        "Звук идёт, только пока зажата клавиша push-to-talk (Настройки → Горячие клавиши)":
            "Audio passes only while the push-to-talk key is held (Settings → Hotkeys)",
        "Новый профиль":
            "New profile",
        "Название":
            "Name",
        "Сохраняет голос, задержку, вычисления и параметры звука.":
            "Saves the voice, latency, compute units and sound parameters.",
        "МИКРОФОН":
            "MIC ON",
        "ОСТАНОВЛЕНО":
            "STOPPED",
        "ОБРАБОТКА":
            "PROCESSING",
        "ОШИБКА":
            "ERROR",
        "Стоп":
            "Stop",
        "Старт":
            "Start",
        "Лог пуст":
            "Log is empty",
        "обработка %.0f из %.0f мс":
            "processing %.0f of %.0f ms",
        "задержка ≈%.0f мс":
            "latency ≈%.0f ms",
        "вход %.0f дБ":
            "input %.0f dB",
        "тишина":
            "silence",
        "Работает: %@":
            "Running: %@",
        "Задержка ≈%.0f мс · обработка %.0f мс":
            "Latency ≈%.0f ms · processing %.0f ms",
        "Без обработки":
            "Bypass",
        "Открыть RVCMac":
            "Open RVCMac",
        "Выйти":
            "Quit",
        "Горячие клавиши (работают глобально)":
            "Hotkeys (work system-wide)",
        "Сочетание занято другим приложением":
            "The shortcut is taken by another app",
        "Сбросить по умолчанию":
            "Reset to defaults",
        "Нажми на поле и затем сочетание. Нужен хотя бы один модификатор (⌘⌥⌃⇧), кроме F-клавиш. ⌫ — очистить, ⎋ — отмена.":
            "Click a field, then press a shortcut. At least one modifier (⌘⌥⌃⇧) is required, except for F-keys. ⌫ clears, ⎋ cancels.",
        "Окно":
            "Window",
        "Оставаться в строке меню после закрытия окна":
            "Stay in the menu bar after the window is closed",
        "Отчёты и приватность":
            "Reports and privacy",
        "Не сохранять в отчётах имена устройств и пути к файлам":
            "Leave device names and file paths out of reports",
        "Аудио обрабатывается только локально. В лог и отчёты звук не пишется; WAV сохраняется лишь по флажку в бенчмарке.":
            "Audio is processed locally only. No audio goes into logs or reports; a WAV is saved only when enabled in the benchmark.",
        "Нажми сочетание…":
            "Press a shortcut…",
        "не задано":
            "not set",
        "Поток обработки не завершился за 3 с":
            "The processing thread did not finish within 3 s",
        "Переключение на лету требует одинаковых настроек задержки":
            "Live switching needs the same latency settings",
        "Ошибка инференса: %@":
            "Inference error: %@",
        "модель":
            "model",
        "вычисления":
            "compute",
        "блок, мс":
            "block, ms",
        "контекст, мс":
            "context, ms",
        "кроссфейд, мс":
            "crossfade, ms",
        "частота выхода":
            "output rate",
        "тип отчёта":
            "report type",
        "источник":
            "source",
        "Полная задержка p50":
            "Total latency p50",
        "Полная задержка p95":
            "Total latency p95",
        "Полная задержка p99":
            "Total latency p99",
        "Загрузка моделей":
            "Model loading",
        "Первый блок":
            "First block",
        "Underrun (события)":
            "Underruns (events)",
        "Ресемплинг входа":
            "Input resampling",
        "Тон (FCPE)":
            "Pitch (FCPE)",
        "Признаки / index":
            "Features / index",
        "Возбуждение (NSF)":
            "Excitation (NSF)",
        "Синтезатор RVC":
            "RVC synthesizer",
        "Ресемплинг + SOLA":
            "Resampling + SOLA",
        "Блок целиком":
            "Whole block",
        "В этой сборке не закреплён Python, и python3.12 из Homebrew не найден. Установи его: brew install python@3.12":
            "This build has no pinned Python and no Homebrew python3.12 was found. Install it: brew install python@3.12",
        "Контрольная сумма скачанного Python не совпала — файл повреждён или подменён. Попробуй ещё раз.":
            "The checksum of the downloaded Python does not match — the file is damaged or was tampered with. Try again.",
        "Шаг «%@» завершился с кодом %@ — подробности в логе.":
            "Step “%@” exited with code %@ — see the log for details.",
        "Создаю окружение Python…":
            "Creating the Python environment…",
        "Обновляю pip…":
            "Updating pip…",
        "Скачиваю библиотеки (torch, coremltools…) — около 1 ГБ":
            "Downloading libraries (torch, coremltools…) — about 1 GB",
        "Скачиваю %@…":
            "Downloading %@…",
        "Устанавливаю пакеты…":
            "Installing packages…",
        "Проверяю установку…":
            "Checking the installation…",
        "Конвертер готов":
            "Converter ready",
        "Скачиваю Python…":
            "Downloading Python…",
        "Скачиваю Python: %@":
            "Downloading Python: %@",
        "Распаковываю Python…":
            "Unpacking Python…",
        "Python не закреплён в сборке — использую %@":
            "No Python pinned in this build — using %@",
        "Нужен конвертер моделей":
            "The model converter is needed",
        "Чтобы превращать RVC-модели в формат Core ML, RVCMac один раз скачает Python и библиотеки (около 1 ГБ, ещё ~400 МБ весов при первой конвертации). Всё хранится в папке приложения, звук никуда не отправляется.":
            "To turn RVC models into Core ML, RVCMac downloads Python and its libraries once (about 1 GB, plus ~400 MB of weights on the first conversion). Everything stays in the app's data folder; no audio is sent anywhere.",
        "Скачать и установить":
            "Download and install",
        "Подготовка…":
            "Preparing…",
        "Установка конвертера в %@":
            "Installing the converter into %@",
        "Конвертер установлен.":
            "Converter installed.",
        "Установка конвертера не удалась":
            "Converter installation failed",
        "Установка конвертера: %@":
            "Converter installation: %@",
        "Не удалось удалить старое окружение: %@":
            "Could not remove the old environment: %@",
        "Язык":
            "Language",
        "Язык интерфейса":
            "Interface language",
        "Как в системе":
            "Same as system",
        "Окна и настройки переключаются сразу, меню приложения — после перезапуска.":
            "Windows and settings switch immediately; the app menu switches after a restart.",
        "Конвертер моделей":
            "Model converter",
        "Состояние":
            "Status",
        "установлен":
            "installed",
        "не установлен — поставится при первом импорте":
            "not installed — will be set up on the first import",
        "Папка данных":
            "Data folder",
        "Переустановить":
            "Reinstall",
        "Установить сейчас":
            "Install now",
        "Открыть папку данных":
            "Open data folder",
    ]
}

/// Translates a Russian source string into the current interface language.
public func tr(_ s: String) -> String { Loc.tr(s) }

/// Translates a format string, then formats it.
public func trf(_ s: String, _ args: CVarArg...) -> String { String(format: Loc.tr(s), arguments: args) }
