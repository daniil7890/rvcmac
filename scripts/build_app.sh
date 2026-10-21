#!/usr/bin/env bash
# Builds RVCMac.app with Swift Package Manager (Command Line Tools are enough, no Xcode needed).
#
#   bash scripts/build_app.sh                    local build, app points at this checkout
#   bash scripts/build_app.sh --release 0.1.0    portable build + dist/RVCMac-0.1.0-arm64.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build.log"
exec > >(tee "$LOG") 2>&1

VERSION="0.1.0-dev"
RELEASE=0
if [[ "${1:-}" == "--release" ]]; then
  RELEASE=1
  VERSION="${2:?usage: build_app.sh --release VERSION}"
fi

echo "=== build $VERSION $(date) ==="
swift --version

cd "$ROOT/app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/RVCMac"

APP="$ROOT/RVCMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RVCMac"

# A local build remembers where its converter and models live; a release build
# falls back to ~/projects/rvcmac (the path used in the README).
HOME_KEY=""
if [[ $RELEASE -eq 0 ]]; then
  HOME_KEY="<key>RVCMacHome</key><string>$ROOT</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.daniil7890.rvcmac</string>
  <key>CFBundleName</key><string>RVCMac</string>
  <key>CFBundleDisplayName</key><string>RVCMac</string>
  <key>CFBundleExecutable</key><string>RVCMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>RVCMac обрабатывает голос с микрофона в реальном времени.</string>
  $HOME_KEY
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "=== built: $APP ==="

if [[ $RELEASE -eq 1 ]]; then
  mkdir -p "$ROOT/dist"
  ZIP="$ROOT/dist/RVCMac-$VERSION-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP"
  echo "=== packaged: $ZIP ==="
fi
