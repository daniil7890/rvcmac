# RVCMac

[Русский](README.md) | **English**

A native real-time RVC voice changer for Apple Silicon Macs. Models run through Core ML on the Neural Engine and GPU. No PyTorch and no browser are involved while it runs.

## How it works

```
mic ─► CoreAudio ─► 16 kHz ─► ContentVec (Core ML, ANE, fp16) ─► index (Accelerate) ─┐
                         └──► FCPE pitch (Core ML, GPU, fp32) ─► f0 / NSF sine ───────┤
                                            RVC synthesizer (Core ML, ANE, fp16) ◄────┘
                                            └─► resampling ─► SOLA crossfade ─► output
```

- **Converter** (`converter/convert.py`, Python) turns an RVC model (`.pth`/`.safetensors`), ContentVec and FCPE into `.mlpackage` files. Shapes are fixed for the chosen latency so Core ML can run the models on the Neural Engine. Before saving, it checks the Core ML output against PyTorch.
- **App** (`app/`, Swift) captures audio through a HAL IOProc. Input and output can be different devices, for example a microphone and BlackHole. `.index` search is exact, via `cblas_sgemm`. Blocks are stitched with SOLA, the same way RVC WebUI and w-okada do it.

Supports RVC v1/v2 with pitch (f0), 32/40/48 kHz, `.index` and Protect.
Models without pitch (nono) are not supported yet.

## Requirements

- Apple Silicon Mac, macOS 14+.
- Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- Homebrew and `python@3.12` (`brew install python@3.12`).
- For output to Discord or OBS: [BlackHole](https://github.com/ExistentialAudio/BlackHole) (`brew install blackhole-2ch`).

## Prebuilt app

[Releases](https://github.com/daniil7890/rvcmac/releases) contain a prebuilt `RVCMac.app`, built by GitHub Actions for every `v*` tag. The build is ad-hoc signed, so after downloading you need to remove the quarantine flag: `xattr -dr com.apple.quarantine RVCMac.app`.

You still need the converter to import models: clone the repository to `~/projects/rvcmac` and run step 1 below. The prebuilt app looks for the converter and models in exactly that location.

## Building from source

```bash
git clone https://github.com/daniil7890/rvcmac.git ~/projects/rvcmac
cd ~/projects/rvcmac

# 1. converter environment (~2 GB) + first model
bash scripts/setup_converter.sh ~/Downloads/voice/model.pth

# 2. the app (or download it from Releases)
bash scripts/build_app.sh
open RVCMac.app
```

The first conversion downloads the [ContentVec](https://huggingface.co/lengyue233/content-vec-best) weights (~380 MB) and [FCPE](https://github.com/CNChTu/FCPE). The first time a model loads in the app can take up to a minute while the Neural Engine compiles it. After that it comes from the cache.

## Usage

The app interface is in Russian; the original labels are given in parentheses.

- **Import… (Импорт…)** — pick a `.pth` or `.safetensors` file. A `.index` in the same folder is picked up automatically. The **Index…** button attaches an index manually.
- **Latency (Задержка)** — Block (Блок), Context (Контекст) and Crossfade (Кроссфейд). Each combination is built once with the **Build (Собрать)** button.
  - Latency ≈ block + processing time.
  - The line at the bottom shows the processing time per block. You can lower the block size while it stays green.
- **Sound (Звук)** — pitch, silence threshold, volume, Index and Protect. Everything changes on the fly.
- **Bypass (Без обработки)** — passes audio straight through so you can check the routing.

From the Terminal:

```bash
venv/bin/python converter/convert.py import --model model.pth [--index added_x.index]
venv/bin/python converter/convert.py config --name model --block-ms 150 --extra-ms 300 --crossfade-ms 100
venv/bin/python converter/convert.py index  --name model --index added_x.index
```

## Credits and licenses

- The RVC model code in `converter/rvc_infer/` comes from [w-okada/voice-changer](https://github.com/w-okada/voice-changer) ([deiteris](https://github.com/deiteris/voice-changer) fork), MIT, see `converter/rvc_infer/LICENSE-voice-changer`. It originally derives from [RVC-Project](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI).
- [ContentVec](https://github.com/auspicious3000/contentvec), [FCPE](https://github.com/CNChTu/FCPE) — weights are downloaded during conversion and are not part of this repository.
- All other code is MIT (see `LICENSE`).

Only use voice models you have the rights to, and don't impersonate real people.
