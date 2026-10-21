# RVCMac

Нативный голосовой чейнджер RVC для macOS на Apple Silicon. Модели работают через Core ML на Neural Engine и GPU, без PyTorch и браузера во время работы.

*Native real-time RVC voice changer for Apple Silicon Macs. Core ML on the Neural Engine and GPU, CoreAudio I/O, SwiftUI.*

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
- Command Line Tools (`xcode-select --install`). Полный Xcode не нужен.
- Homebrew и `python@3.12` (`brew install python@3.12`).
- Для вывода в Discord или OBS: [BlackHole](https://github.com/ExistentialAudio/BlackHole) (`brew install blackhole-2ch`).

## Готовая сборка

В [Releases](https://github.com/daniil7890/rvcmac/releases) лежит собранный `RVCMac.app`. Его собирает GitHub Actions на каждый тег `v*`. Сборка подписана ad-hoc, поэтому после скачивания нужно снять карантин: `xattr -dr com.apple.quarantine RVCMac.app`.

Для импорта моделей всё равно нужен конвертер: клонируй репозиторий в `~/projects/rvcmac` и выполни шаг 1 ниже. Готовая сборка ищет конвертер и модели именно там.

## Установка из исходников

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
  - Задержка ≈ блок + время обработки.
  - Строка внизу показывает время обработки блока. Блок можно уменьшать, пока она зелёная.
- **Звук** — тон, порог тишины, громкость, Index и Protect. Всё меняется на лету.
- **Без обработки** — пропускает звук насквозь, чтобы проверить маршрут.

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
