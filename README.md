# RVCMac

**Русский** | [English](README.en.md)

Нативный голосовой чейнджер RVC для macOS на Apple Silicon. Модели работают через Core ML на Neural Engine и GPU, без PyTorch и браузера во время работы.

## Как это устроено

```
микрофон ─► CoreAudio ─► 16 кГц ─► ContentVec (Core ML, ANE, fp16) ─► index (Accelerate) ─┐
                              └──► FCPE pitch (Core ML, GPU, fp32) ─► f0 / NSF-синусоида ──┤
                                                    RVC-синтезатор (Core ML, ANE, fp16) ◄─┘
                                                    └─► ресемплинг ─► SOLA-кроссфейд ─► выход
```

- **Конвертер** (`converter/convert.py`, Python) переводит RVC-модель (`.pth`/`.safetensors`), ContentVec и FCPE в `.mlpackage`. Размеры фиксируются под выбранную задержку, чтобы Core ML мог запускать модели на Neural Engine. Перед сохранением он сверяет результат Core ML с PyTorch.
- **Приложение** (`app/`, Swift) берёт звук через HAL IOProc (вход и выход могут быть разными устройствами, например микрофон и BlackHole). Поиск по `.index` точный, через `cblas_sgemm`. Склейка блоков — SOLA, как в RVC WebUI и w-okada.

Поддерживаются RVC v1/v2 с тоном (f0), 32/40/48 кГц, `.index`, Protect.
Модели без тона (nono) пока не поддерживаются.

## Требования

- Mac на Apple Silicon, macOS 14+.
- Для вывода в Discord или OBS: [BlackHole](https://github.com/ExistentialAudio/BlackHole) (`brew install blackhole-2ch`).

## Установка

1. Скачай `RVCMac-…-arm64.zip` из [Releases](https://github.com/daniil7890/rvcmac/releases), распакуй и перенеси `RVCMac.app` в «Программы».
2. Сборка подписана ad-hoc (без Apple Developer ID), поэтому один раз сними карантин:
   ```bash
   xattr -dr com.apple.quarantine /Applications/RVCMac.app
   ```
3. Открой RVCMac и нажми «Импорт…». При первом импорте приложение само скачает конвертер: Python и библиотеки, около 1 ГБ, один раз. Python берётся из [python-build-standalone](https://github.com/astral-sh/python-build-standalone), его SHA-256 зашит в сборку. Ставить Homebrew, Python или клонировать репозиторий не нужно.

Голоса, профили, отчёты и окружение конвертера лежат в `~/Library/Application Support/RVCMac`. Удалить всё — значит удалить приложение и эту папку. Если голоса уже лежат в `~/projects/rvcmac` от прошлых версий, приложение продолжит брать их оттуда.

Язык интерфейса — русский или английский, по языку системы. Переключается в Настройках (⌘,).

## Сборка из исходников

Нужны Command Line Tools (`xcode-select --install`), полный Xcode не требуется. Для конвертера из Терминала — Homebrew `python@3.12`.

```bash
git clone https://github.com/daniil7890/rvcmac.git ~/projects/rvcmac
cd ~/projects/rvcmac

# 1. окружение конвертера (~2 ГБ) + первая модель
bash scripts/setup_converter.sh ~/Downloads/voice/model.pth

# 2. приложение (или скачай готовое из Releases)
bash scripts/build_app.sh
open RVCMac.app
```

При первой конвертации скачиваются веса [ContentVec](https://huggingface.co/lengyue233/content-vec-best) (~380 МБ) и [FCPE](https://github.com/CNChTu/FCPE). Первый запуск модели в приложении занимает до минуты, пока Neural Engine её компилирует. Дальше она берётся из кэша.

## Использование

- **Импорт…** — выбрать `.pth` или `.safetensors`. `.index` из той же папки подхватывается автоматически. Кнопка **Index…** подключает индекс вручную.
- **Задержка** — Блок, Контекст и Кроссфейд. Каждое сочетание собирается один раз кнопкой «Собрать».
  - Полная задержка ≈ блок + кроссфейд + 10 мс SOLA + обработка + очередь вывода + задержки устройств. Измеренное значение показывает строка внизу и окно «Диагностика».
  - Строка внизу показывает время обработки блока. Блок можно уменьшать, пока она зелёная и не растёт счётчик underrun.
- **Звук** — тон, порог тишины, громкость, Index и Protect. Всё меняется на лету.
- **Без обработки (bypass)** — пропускает звук насквозь, чтобы проверить маршрут. **Mute** и **Push-to-talk** глушат выход с короткой рампой, без щелчка.
- **Профили** — голос, задержка, вычисления и параметры звука под одним именем. Если у голосов одинаковая задержка, переключение идёт без остановки: новый голос готовится в фоне и подмешивается кроссфейдом.
- **Горячие клавиши** (Настройки, ⌘,) работают глобально: старт/стоп ⌥⌘R, mute ⌥⌘M, bypass ⌥⌘B. Push-to-talk и «следующий профиль» назначаются там же.
- **Строка меню** — состояние, mute, bypass и профили. Можно оставить приложение в строке меню после закрытия окна.

### Диагностика и бенчмарк

Окно «Диагностика» (кнопка внизу главного окна):

- **Live** — полная задержка (p50/p95/p99) с разбивкой: конвейер от захвата до вывода, алгоритмическая часть, задержки устройств. Плюс время каждого этапа (ContentVec, FCPE, index, NSF, синтезатор, SOLA), underrun и переполнения, CPU, память, тепловое состояние. «Сохранить отчёт сессии» пишет JSON и CSV в `reports/`.
- **Бенчмарк** — воспроизводимый тест на аудиофайле или встроенном синтетическом сигнале. Отдельно меряется холодный старт, потом прогрев и несколько прогонов в реальном темпе. Результат первого прогона можно сохранить в WAV, чтобы послушать.
- **Сравнение** — два отчёта бок о бок с дельтой. Если конфигурации различаются, окно предупреждает.

Как снимать baseline и что нашёл аудит, описано в [docs/AUDIT.md](docs/AUDIT.md).

`.pth` — это pickle, и при загрузке он может выполнить код. Поэтому конвертер по умолчанию открывает модели в безопасном режиме (`weights_only=True`). Если файл содержит что-то кроме весов, приложение спросит, доверяешь ли ты источнику. Из Терминала то же самое делает флаг `--unsafe-pickle`. По возможности бери `.safetensors`.

Из Терминала:

```bash
venv/bin/python converter/convert.py import --model model.pth [--index added_x.index]
venv/bin/python converter/convert.py config --name model --block-ms 150 --extra-ms 300 --crossfade-ms 100
venv/bin/python converter/convert.py index  --name model --index added_x.index
```

## Благодарности и лицензии

- Код моделей RVC в `converter/rvc_infer/` взят из [w-okada/voice-changer](https://github.com/w-okada/voice-changer) (форк [deiteris](https://github.com/deiteris/voice-changer)), MIT, см. `converter/rvc_infer/LICENSE-voice-changer`. Изначально он происходит из [RVC-Project](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI).
- [ContentVec](https://github.com/auspicious3000/contentvec), [FCPE](https://github.com/CNChTu/FCPE) — веса скачиваются при конвертации и в репозиторий не входят.
- Остальной код — MIT (см. `LICENSE`).

Используй только те голосовые модели, на которые у тебя есть права, и не выдавай себя за реальных людей.
