#!/bin/zsh
# Builds a release binary and wraps it in a minimal .app bundle (menu-bar agent).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Apple Music Presence"
BUNDLE_ID="dev.burbujamc.apple-music-presence"
VERSION="${VERSION:-1.0.0}"
OUT="build/$APP_NAME.app"

swift build -c release 2>&1 | grep -vE "^\s*$" | tail -5
BIN="$(swift build -c release --show-bin-path)/AppleMusicPresence"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Apple Music Presence reads the current track from Music to show it as your Discord status.</string>
    <key>NSHumanReadableCopyright</key><string>BSD-3-Clause</string>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$OUT/Contents/PkgInfo"

codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT" >/dev/null
echo "Built $OUT"
