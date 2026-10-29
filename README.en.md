# RVCMac

[Русский](README.md) | **English**

[![Build](https://github.com/daniil7890/rvcmac/actions/workflows/build.yml/badge.svg)](https://github.com/daniil7890/rvcmac/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/daniil7890/rvcmac)](https://github.com/daniil7890/rvcmac/releases)

A native RVC voice changer for Apple Silicon Macs. Your voice is converted in real time, locally: the models run through Core ML on the Neural Engine and GPU. No PyTorch, browser or server is involved while it runs.

<p align="center"><img src="app/Resources/AppIcon.png" width="128" alt="RVCMac"></p>

## Features

- RVC v1/v2 with pitch (f0), 32/40/48 kHz, `.index` and Protect. Models without pitch (nono) are not supported yet.
- Output to any device: speakers, headphones, [BlackHole](https://github.com/ExistentialAudio/BlackHole) for Discord and OBS.
- Voice profiles and live voice switching without stopping audio.
- Mute, push-to-talk and global hotkeys; control from the menu bar.
- A Diagnostics window: total latency with a breakdown, per-stage timing, underruns, CPU and memory, plus a benchmark and report comparison.
- English and Russian interface.
- One download: the app sets up its model converter by itself on the first import.

### Latency in practice

MacBook Air M2, "Neural Engine + GPU", output to BlackHole:

| Block / context / crossfade | Total latency (p50) | Block processing (p50 / p95) |
|---|---|---|
| 150 / 500 / 100 ms | 548 ms | ~45 ms |
| **100 / 500 / 50 ms** | **321 ms** | 50 / 66 ms |

Total latency is the path from sound at the microphone to sound at the output. It is made up of the algorithm (block + crossfade), processing, the output queue and device latency. Diagnostics shows the numbers for your Mac.

## Install

1. Download `RVCMac-…-arm64.zip` from [Releases](https://github.com/daniil7890/rvcmac/releases), unzip it and move `RVCMac.app` to Applications.
2. The build is ad-hoc signed, without an Apple Developer ID, so macOS will refuse to open it. Remove the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/RVCMac.app
   ```
3. Open RVCMac and press **Import…**. On the first import the app offers to download its converter: Python and libraries, about 1 GB, once. The first conversion also fetches the ContentVec and FCPE weights, about 400 MB.

No Homebrew, Python or repository clone is needed.

**Requirements:** Apple Silicon Mac, macOS 14 or later. Discord and OBS need [BlackHole](https://github.com/ExistentialAudio/BlackHole) (`brew install blackhole-2ch`).

## Quick start

1. **Import…** → choose a `.pth` or `.safetensors`. A `.index` in the same folder is picked up automatically; otherwise attach it with **Index…**.
2. **Latency:** start with 100 / 500 / 50 ms. If the model is not built for these settings yet, press **Build**.
3. **Audio:** input is your microphone, output is BlackHole 2ch. In Discord or OBS pick BlackHole as the microphone.
4. **Start.** The first run of a model takes up to a minute while the Neural Engine compiles it; after that it comes from the cache.

## Usage

- **Sound** — pitch, silence gate, volume, Index and Protect. Everything changes on the fly.
- **Tuning latency.** The bottom line shows the processing time per block. Lower the block size while the line stays green and the underrun counter in Diagnostics does not grow. Context is the window length ContentVec and FCPE see: a longer one is more stable but takes longer to process.
- **Bypass** passes audio straight through so you can check the routing. **Mute** and **Push-to-talk** silence the output with a short ramp, without clicks.
- **Profiles** store the voice, latency, compute units and sound parameters. Between voices with the same latency settings the switch happens without stopping: the new voice is prepared in the background and crossfaded in.
- **Hotkeys** work system-wide and are set in Settings (⌘,). Defaults: start/stop ⌥⌘R, mute ⌥⌘M, bypass ⌥⌘B. Push-to-talk and "next profile" are assigned there too.
- **Menu bar** — status, mute, bypass and profiles. The app can stay there after the window is closed.
- **Language** follows the system, or set it in Settings.

### Diagnostics and benchmark

The **Diagnostics** button at the bottom of the main window:

- **Live** — total latency p50/p95/p99 and its parts: capture-to-playback pipeline, algorithmic, devices. Per-stage timing: ContentVec, FCPE, index, NSF, synthesizer, SOLA. Underruns, overflows, CPU, memory, thermal state and a chart. "Save session report" writes JSON and CSV.
- **Benchmark** — a repeatable test on an audio file or a built-in signal. Cold start is measured separately, then a warm-up and several real-time-paced runs. The output can be saved as WAV for listening.
- **Compare** — two reports side by side with deltas. The window warns when their settings differ.

The measurement method and the audio path audit are in [docs/AUDIT.md](docs/AUDIT.md) (Russian).

## How it works

```
mic ─► Core Audio ─► 16 kHz ─► ContentVec (Core ML, ANE) ─► index (Accelerate) ─┐
                          └──► FCPE (Core ML, GPU, fp32) ─► f0 / NSF sine ──────┤
                                          RVC synthesizer (Core ML, ANE) ◄──────┘
                                          └─► resampling ─► SOLA crossfade ─► output
```

- **Converter** (`converter/convert.py`, Python) turns an RVC model, ContentVec and FCPE into `.mlpackage` files. Shapes are fixed for the chosen latency so the models run on the Neural Engine. Before saving, the converter checks the Core ML output against PyTorch.
- **App** (`app/`, Swift) captures and plays audio through HAL IOProcs. The audio callbacks take no locks and allocate nothing: data goes through lock-free rings on C11 atomics (`RVCMacRT`). Inference runs on its own thread. The `.index` search is exact, via `cblas_sgemm`. Blocks are joined with SOLA, as in RVC WebUI and w-okada.
- **First run.** The converter scripts ship inside `RVCMac.app`. Python is downloaded from [python-build-standalone](https://github.com/astral-sh/python-build-standalone); its SHA-256 is pinned in the build and checked after download. The libraries go into a separate environment in the data folder.

## Privacy and security

- Audio is processed locally only. No audio goes into logs or reports; a WAV is saved only when you enable it in the benchmark.
- Device names and file paths are left out of reports by default.
- A `.pth` file is a pickle and can execute code when loaded, so models are opened in safe mode (`weights_only=True`). If a file holds more than plain weights, the app asks whether you trust its source. Prefer `.safetensors` when available.
- The network is used only for the one-time converter setup and the ContentVec/FCPE weights. Voice models are never downloaded automatically.

## Where data lives

Voices, profiles, reports, the log and the converter environment are kept in `~/Library/Application Support/RVCMac`. To open it: Settings → Model converter → Open data folder.

To remove everything, delete `RVCMac.app` and that folder. If voices from version 0.1 live in `~/projects/rvcmac` and the new folder does not exist yet, the app keeps using them from there.

## Building from source

Command Line Tools are enough (`xcode-select --install`); full Xcode is not needed.

```bash
git clone https://github.com/daniil7890/rvcmac.git
cd rvcmac
bash scripts/build_app.sh            # local build: data lives in the repository folder
open RVCMac.app

bash scripts/build_app.sh --release 0.2.0   # like a release: data in Application Support + dist/*.zip
```

Converter from the Terminal (needs Homebrew `python@3.12`):

```bash
bash scripts/setup_converter.sh ~/Downloads/voice/model.pth   # environment + first model
venv/bin/python converter/convert.py import --model model.pth [--index added_x.index]
venv/bin/python converter/convert.py config --name model --block-ms 100 --extra-ms 500 --crossfade-ms 50
venv/bin/python converter/convert.py index  --name model --index added_x.index
```

The unit tests (`cd app && swift test`) need XCTest, which only full Xcode provides, so they run in GitHub Actions on every push.

### Layout

| Path | What is there |
|---|---|
| `app/Sources/RVCMac` | the app: UI, audio, engine, diagnostics, converter setup |
| `app/Sources/RVCMacCore` | platform-independent logic: statistics, reports, profiles, localization |
| `app/Sources/RVCMacRT` | real-time primitives in C: ring buffer, seqlock, atomics |
| `app/Tests` | unit tests |
| `converter/` | model converter to Core ML |
| `scripts/` | build, converter setup, CI helpers |
| `docs/AUDIT.md` | audio path audit and measurement method |

## Credits and licenses

- The RVC model code in `converter/rvc_infer/` comes from [w-okada/voice-changer](https://github.com/w-okada/voice-changer) ([deiteris](https://github.com/deiteris/voice-changer) fork), MIT, see `converter/rvc_infer/LICENSE-voice-changer`. It originally derives from [RVC-Project](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI).
- [ContentVec](https://github.com/auspicious3000/contentvec) and [FCPE](https://github.com/CNChTu/FCPE) weights are downloaded during conversion and are not part of this repository.
- Python builds come from [python-build-standalone](https://github.com/astral-sh/python-build-standalone).
- All other code is MIT (see `LICENSE`). Written together with Claude (Anthropic).

Only use voice models you have the rights to, and don't impersonate real people.
