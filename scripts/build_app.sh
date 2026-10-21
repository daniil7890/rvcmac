#!/usr/bin/env bash
# Builds RVCMac.app with Swift Package Manager (Command Line Tools are enough, no Xcode needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build.log"
exec > >(tee "$LOG") 2>&1
echo "=== build $(date) ==="
swift --version

cd "$ROOT/app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/RVCMac"

APP="$ROOT/RVCMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RVCMac"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.rvcmac</string>
  <key>CFBundleName</key><string>RVCMac</string>
  <key>CFBundleDisplayName</key><string>RVCMac</string>
  <key>CFBundleExecutable</key><string>RVCMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>RVCMac обрабатывает голос с микрофона в реальном времени.</string>
  <key>RVCMacHome</key><string>$ROOT</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "=== built: $APP ==="
