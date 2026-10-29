#!/usr/bin/env bash
# Builds RVCMac.app with Swift Package Manager (Command Line Tools are enough, no Xcode needed).
#
#   bash scripts/build_app.sh                    local build, app points at this checkout
#   bash scripts/build_app.sh --release 0.1.0    portable build + dist/RVCMac-0.1.0-arm64.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build.log"
exec > >(tee "$LOG") 2>&1

VERSION="0.2.0-dev"
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

# icon, localized Info.plist strings
# build the full icon set with Apple's own tools when available (all 10 sizes), else use the committed .icns
ICONSET="$ROOT/app/.build/AppIcon.iconset"
if command -v iconutil >/dev/null && command -v sips >/dev/null; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/app/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/app/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi
cp -R "$ROOT/app/Resources/en.lproj" "$ROOT/app/Resources/ru.lproj" "$APP/Contents/Resources/"

# the model converter travels inside the app; its Python environment is installed on first use
mkdir -p "$APP/Contents/Resources/converter"
rsync -a --exclude "__pycache__" --exclude "*.pyc" "$ROOT/converter/" "$APP/Contents/Resources/converter/"

# Standalone Python the app downloads on first use, pinned by URL + SHA-256.
# Required for release builds; optional locally (falls back to Homebrew python3.12).
PY_KEYS=""
if PIN="$(python3 "$ROOT/scripts/resolve_python.py" 2>/dev/null)"; then
  PY_URL="${PIN%% *}"; PY_SHA="${PIN##* }"
  echo "pinned Python: $PY_URL ($PY_SHA)"
  PY_KEYS="<key>RVCMacPythonURL</key><string>$PY_URL</string><key>RVCMacPythonSHA256</key><string>$PY_SHA</string>"
elif [[ $RELEASE -eq 1 ]]; then
  echo "ERROR: could not resolve the standalone Python for the release build"; exit 1
else
  echo "note: Python not pinned (offline?) — the app will use Homebrew python3.12 for the converter"
fi

# A local build keeps its data in this checkout; a release build uses ~/Library/Application Support/RVCMac.
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>RVCMac converts your voice from the microphone in real time, locally on this Mac.</string>
  $HOME_KEY
  $PY_KEYS
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
# Finder and the Dock cache icons per path: re-register so a rebuilt app shows its new icon
touch "$APP"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP" || true
echo "=== built: $APP ==="

if [[ $RELEASE -eq 1 ]]; then
  mkdir -p "$ROOT/dist"
  ZIP="$ROOT/dist/RVCMac-$VERSION-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP"
  echo "=== packaged: $ZIP ==="
fi
