RVCMac for Apple Silicon Macs (macOS 14+). Интерфейс на русском и английском.

**Установка / Install**

1. Скачай `RVCMac-…-arm64.zip`, распакуй и перенеси `RVCMac.app` в «Программы». / Download, unzip, move `RVCMac.app` to Applications.
2. Сборка подписана ad-hoc, без Apple Developer ID, поэтому при первом запуске macOS её заблокирует. Сними карантин / The build is ad-hoc signed, so remove the quarantine flag once:
   ```
   xattr -dr com.apple.quarantine /Applications/RVCMac.app
   ```
3. Открой приложение и нажми «Импорт…». При первом импорте RVCMac сам скачает конвертер (Python и библиотеки, около 1 ГБ, один раз). Клонировать репозиторий не нужно. / Open the app and press Import…; on the first import RVCMac downloads its converter (Python + libraries, ~1 GB, once).

Данные (голоса, отчёты, профили, окружение конвертера) лежат в `~/Library/Application Support/RVCMac`. / Data lives in `~/Library/Application Support/RVCMac`.
