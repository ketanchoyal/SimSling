#!/bin/zsh
# Builds build/SimDrop.app, a universal (Apple Silicon + Intel) menu bar app.
# The same binary is also the `simdrop` CLI. Ad-hoc signed: no certificate or team.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(cat VERSION)}
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/SimDrop"
APP=build/SimDrop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SimDrop"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SimDrop</string>
    <key>CFBundleDisplayName</key><string>SimDrop</string>
    <key>CFBundleIdentifier</key><string>com.ketanchoyal.SimDrop</string>
    <key>CFBundleExecutable</key><string>SimDrop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
