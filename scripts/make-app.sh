#!/bin/bash
# Builds dist/Toolbox.app (+ dist/Toolbox.zip) with yt-dlp, ffmpeg and ffprobe inside.
#
#   scripts/fetch-tools.sh && scripts/make-app.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/make-app.sh
#
# Without SIGN_IDENTITY the app is ad-hoc signed: fine on this Mac, not for distribution.
# For distribution also notarize: xcrun notarytool submit dist/Toolbox.zip --wait ... ; xcrun stapler staple dist/Toolbox.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${TOOLS_DIR:-$ROOT/build/tools}"
# Version comes from AppVersion.current in ReleaseNotes.swift (override with VERSION=... only for experiments).
VERSION="${VERSION:-$(sed -n 's/^ *static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/Toolbox/Support/ReleaseNotes.swift" | head -1)}"
[ -n "$VERSION" ] || { echo "Could not read the version from ReleaseNotes.swift"; exit 1; }
BUILD="${BUILD:-$VERSION}"   # CFBundleVersion; CI passes its run number
IDENTITY="${SIGN_IDENTITY:--}"
ARCH_FLAGS=(--arch arm64)
[ -n "${ARCHS:-}" ] && ARCH_FLAGS=($(for a in $ARCHS; do echo --arch "$a"; done))
APP="$ROOT/dist/Toolbox.app"

for t in yt-dlp ffmpeg ffprobe; do
  [ -x "$TOOLS/$t" ] || { echo "Missing $TOOLS/$t. Run scripts/fetch-tools.sh first."; exit 1; }
done

cd "$ROOT"
echo "==> llama.cpp (Vault search)"
scripts/build-llama.sh

echo "==> swift build (release)"
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Toolbox"

echo "==> assembling $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN" "$APP/Contents/MacOS/Toolbox"
for t in yt-dlp ffmpeg ffprobe; do cp "$TOOLS/$t" "$APP/Contents/Resources/$t"; done
cp "$ROOT/scripts/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Toolbox</string>
  <key>CFBundleDisplayName</key><string>Toolbox</string>
  <key>CFBundleIdentifier</key><string>com.toolbox.app</string>
  <key>CFBundleExecutable</key><string>Toolbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Toolbox records your voice with a screen recording when you turn on Microphone.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Toolbox turns the speech in your videos into captions on this Mac. Nothing is uploaded.</string>
</dict>
</plist>
PLIST

echo "==> signing ($IDENTITY)"
sign() { codesign --force --sign "$IDENTITY" --options runtime ${TIMESTAMP:+--timestamp} "$@"; }
[ "$IDENTITY" != "-" ] && TIMESTAMP=1
sign --entitlements "$ROOT/scripts/helpers.entitlements" "$APP/Contents/Resources/yt-dlp"
sign "$APP/Contents/Resources/ffmpeg"
sign "$APP/Contents/Resources/ffprobe"
sign --entitlements "$ROOT/scripts/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

( cd "$ROOT/dist" && rm -f Toolbox.zip && ditto -c -k --keepParent Toolbox.app Toolbox.zip )
echo "==> done"
du -sh "$APP" "$ROOT/dist/Toolbox.zip"
echo "Open with: open dist/Toolbox.app"
