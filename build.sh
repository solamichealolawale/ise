#!/bin/bash
# Builds Ise.app into build/ so it runs without a Dock icon.
# ISE_BUILD_DIR keeps Swift's build files elsewhere, so a plugin update can reuse them.
set -euo pipefail
cd "$(dirname "$0")"

scratch="${ISE_BUILD_DIR:-.build}"
swift build -c release --scratch-path "$scratch"

version=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' .claude-plugin/plugin.json)
app="build/Ise.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$scratch/release/Ise" "$app/Contents/MacOS/Ise"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ise</string>
    <key>CFBundleIdentifier</key><string>io.github.solamichealolawale.ise</string>
    <key>CFBundleExecutable</key><string>Ise</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
