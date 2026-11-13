# RVCMac — контекст для агента

Нативный real-time RVC войс-чейнджер для macOS / Apple Silicon.
Swift + Core ML, ввод/вывод через CoreAudio HAL. Python — только конвертер
моделей, в real-time пути его нет. Общение с пользователем — по-русски, кратко.

## Где мы
- Рабочая ветка: v0.3-audit (main = релиз 0.2.0, в неё не коммитим).
- План: docs/SPEC_030.md. Аудит и статусы задач: docs/AUDIT_030.md.
  Замеры: docs/BENCHMARKS.md. Перед задачей читай релевантный раздел аудита.
- Закрыто: B1 (отставание входа), B2 (autoreleasepool, утечка ~1 ГБ/мин),
  C1 (двойной движок), C2 (тайм-аут stop), B4 (экспорт не блокирует воркер),
  B5 (освобождение моделей в фоне), D1 (щелчки gate). Не переделывать.
- Открыто: отмена загрузки кнопкой «Стоп». Затем очередь «Щелчки»:
  A2, A3, D2, D3, D5.

## Архитектура
- app/Sources/RVCMacEngine — движок (VoicePipeline, VoiceEngine, AudioIO,
  Resampler, ModelLibrary, Diagnostics), без UI.
- app/Sources/RVCMac — SwiftUI + AppState. RVCMacCore — статистика/отчёты/
  профили/L10n. RVCMacRT — C11 lock-free кольца и seqlock.
- app/Sources/RVCMacHarness — офлайн-харнесс (CLI), TestAudio/ — тестовая речь,
  scripts/ — метрики качества.

## Жёсткие правила
- В IOProc и RT-путях: никаких локов, аллокаций, логов, файлового I/O.
  Обмен только через кольца RVCMacRT. SPSC не ломать.
- Формы тензоров статические: новая конфигурация блок/контекст/кроссфейд =
  конвертация через converter/convert.py. Динамические формы не вводить.
- Одна задача = один коммит. После каждого: cd app && swift test (55 тестов,
  все зелёные) и swift build -c release --arch arm64.
- Изменения движка проверять харнессом (A/B до/после), регрессии качества —
  скриптом метрик из scripts/ по TestAudio.
- UI-строки только через L10n (ru/en), кириллицу в коде вне L10n не добавлять.
- Симлинки models/ и venv/ не коммитить, git add точечно, не -A.

## Команды
- Сборка приложения: bash scripts/build_app.sh
- Тесты: cd app && swift test   (Xcode установлен, всё локально)
- Харнесс: swift run -c release --package-path app rvcmac-harness --help

## Субагенты
.claude/agents — оригиналы (rt-audio-reviewer, regression-checker,
benchmark-runner). Рабочие копии в .qwen/agents, адаптированы под Qwen Code.
После изменений RT-кода — прогон rt-audio-reviewer.