#!/usr/bin/env bash
set -euo pipefail

RUNFILES_DIR="${RUNFILES_DIR:-$0.runfiles}"
BIN_PATH="$RUNFILES_DIR/_main/macos/FolioApp/FolioCLI"
if [[ ! -x "$BIN_PATH" ]]; then
  BIN_PATH="$(cd "$(dirname "$0")" && pwd)/FolioCLI"
fi

APP_BUNDLE="${TMPDIR:-/tmp}/Folio.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp -f "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/Folio"
chmod +x "$APP_BUNDLE/Contents/MacOS/Folio"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Folio</string>
    <key>CFBundleIdentifier</key>
    <string>app.folio.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Folio</string>
    <key>CFBundleDisplayName</key>
    <string>Folio</string>
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

exec "$APP_BUNDLE/Contents/MacOS/Folio" "$@"
