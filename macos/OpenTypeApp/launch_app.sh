#!/usr/bin/env bash
set -euo pipefail

RUNFILES_DIR="${RUNFILES_DIR:-$0.runfiles}"
BIN_PATH="$RUNFILES_DIR/_main/macos/OpenTypeApp/OpenTypeCLI"
if [[ ! -x "$BIN_PATH" ]]; then
  BIN_PATH="$(cd "$(dirname "$0")" && pwd)/OpenTypeCLI"
fi

APP_BUNDLE="${TMPDIR:-/tmp}/OpenType.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp -f "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/OpenType"
chmod +x "$APP_BUNDLE/Contents/MacOS/OpenType"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenType</string>
    <key>CFBundleIdentifier</key>
    <string>app.opentype.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
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

exec "$APP_BUNDLE/Contents/MacOS/OpenType" "$@"
