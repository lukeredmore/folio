#!/usr/bin/env bash
set -euo pipefail

export CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache
swift build -c release --disable-sandbox --cache-path /tmp/spm-cache -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

APP_DIR="OpenType.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/OpenType "$APP_DIR/Contents/MacOS/OpenType"
chmod +x "$APP_DIR/Contents/MacOS/OpenType"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OpenType</string>
    <key>CFBundleIdentifier</key>
    <string>dev.opentype.mac</string>
    <key>CFBundleName</key>
    <string>OpenType</string>
    <key>CFBundleDisplayName</key>
    <string>OpenType</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "Built native macOS bundle at: $(pwd)/$APP_DIR"
