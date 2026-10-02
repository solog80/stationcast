#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Building StationCast NDI Bridge Go binary for macOS..."
go build -o StationCast_NDI_Bridge .

APP_NAME="StationCast NDI Bridge.app"
APP_DIR="$DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 Creating macOS App Bundle: $APP_NAME..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp StationCast_NDI_Bridge "$MACOS_DIR/StationCast_NDI_Bridge"
if [ -f "smpte_color_bars.webp" ]; then
    cp smpte_color_bars.webp "$MACOS_DIR/smpte_color_bars.webp"
    cp smpte_color_bars.webp "$RESOURCES_DIR/smpte_color_bars.webp"
fi
if [ -f "ndi_bridge_config.json" ]; then
    cp ndi_bridge_config.json "$MACOS_DIR/ndi_bridge_config.json"
fi

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>StationCast NDI Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>StationCast NDI Bridge</string>
    <key>CFBundleIdentifier</key>
    <string>tv.stationcast.ndi-bridge</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>StationCast_NDI_Bridge</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ App bundle created successfully: $APP_DIR"
echo "💡 Launching app in background (Terminal-free)..."
open "$APP_DIR"
