Готовая сборка RVCMac для Mac на Apple Silicon (macOS 14+).

**Установка**

1. Скачай `RVCMac-…-arm64.zip`, распакуй и перенеси `RVCMac.app` куда удобно.
2. Сборка подписана ad-hoc, без Apple Developer ID, поэтому macOS её заблокирует. Сними карантин:
   ```
   xattr -dr com.apple.quarantine /путь/к/RVCMac.app
   ```
3. Для импорта моделей нужен конвертер. Склонируй репозиторий в `~/projects/rvcmac` и запусти `bash scripts/setup_converter.sh` (см. README).
