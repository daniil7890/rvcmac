RVCMac for Apple Silicon Macs (macOS 14+). Интерфейс на русском и английском.

**Установка / Install**

1. Скачай `RVCMac-…-arm64.zip`, распакуй и перенеси `RVCMac.app` в «Программы». / Download, unzip, move `RVCMac.app` to Applications.
2. Сборка подписана ad-hoc, без Apple Developer ID, поэтому при первом запуске macOS её заблокирует. Сними карантин / The build is ad-hoc signed, so remove the quarantine flag once:
   ```
   xattr -dr com.apple.quarantine /Applications/RVCMac.app
   ```
3. Открой приложение и нажми «Импорт…». При первом импорте RVCMac сам скачает конвертер (Python и библиотеки, около 1 ГБ, один раз). Клонировать репозиторий не нужно. / Open the app and press Import…; on the first import RVCMac downloads its converter (Python + libraries, ~1 GB, once).

Данные (голоса, отчёты, профили, окружение конвертера) лежат в `~/Library/Application Support/RVCMac`. / Data lives in `~/Library/Application Support/RVCMac`.

**Что нового в 0.2.0 / What's new**

- Задержка: прогрев моделей до старта и короткая очередь вывода. На M2 Air при 100/500/50 мс полная задержка около 320 мс (раньше около 700). / Latency: model warm-up and a short output queue, ~320 ms total on an M2 Air at 100/500/50 ms (was ~700).
- Окно «Диагностика»: полная задержка с разбивкой, этапы, underrun, CPU и память, бенчмарк, сравнение отчётов. / Diagnostics window: latency breakdown, stages, underruns, CPU/memory, benchmark, report comparison.
- Аудио без блокировок в real-time потоках, реакция на отключение устройств. / Lock-free real-time audio, device disconnect handling.
- Профили, смена голоса на лету, mute, push-to-talk, глобальные горячие клавиши, строка меню. / Profiles, live voice switching, mute, push-to-talk, global hotkeys, menu bar.
- Английский интерфейс, иконка, конвертер ставится сам при первом импорте. / English UI, app icon, the converter installs itself on first import.
- Безопасная загрузка `.pth` (`weights_only`). / Safe `.pth` loading.
