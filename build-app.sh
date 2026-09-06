#!/bin/bash
#
# Builds Macaroni and wraps it in a real .app bundle.
#
# Why the bundle: per-app volume uses Core Audio process taps, which need the
# audio-recording permission. macOS only remembers a permission grant for a
# signed app with a bundle identifier — a bare `swift build` binary gets asked
# every launch (or silently refused). So: Info.plist + ad-hoc signature.
#
# Usage:  ./build-app.sh        then double-click Macaroni.app
set -euo pipefail

APP_NAME="Macaroni"
BUNDLE_ID="com.hirdyanshu.macaroni"
APP_DIR="${APP_NAME}.app"

echo "→ Building release binary…"
swift build -c release

BINARY_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "→ Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <!-- Menu bar only: no Dock icon, no Cmd+Tab entry. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Macaroni taps an app's audio so it can play that app at your chosen volume.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Macaroni needs audio access to control the volume of individual apps.</string>
</dict>
</plist>
PLIST

echo "→ Ad-hoc signing…"
codesign --force --sign - --timestamp=none "${APP_DIR}"

echo ""
echo "✅ Built ${APP_DIR}"
echo "   Launch it:      open ${APP_DIR}"
echo "   Install it:     mv ${APP_DIR} /Applications/"
echo ""
echo "First time you turn an app's volume down, macOS will ask for audio"
echo "permission. Grant it, then try the slider again."
