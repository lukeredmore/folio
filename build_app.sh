#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Release builds must be optimized: the default fastbuild mode ships an unoptimized Rust engine and Swift app.
bazel build -c opt //:FolioApp

BUILT_APP="$SCRIPT_DIR/bazel-bin/macos/FolioApp/FolioApp_archive-root/Folio.app"
rm -rf "$SCRIPT_DIR/Folio.app"
cp -R "$BUILT_APP" "$SCRIPT_DIR/Folio.app"
chmod -R u+w "$SCRIPT_DIR/Folio.app"

# Stamp monotonically increasing build number, git SHA, and independent Rust engine version into Folio.app
PLIST_PATH="$SCRIPT_DIR/Folio.app/Contents/Info.plist"
BUILD_NUM="${FOLIO_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COMMIT_SHA="${FOLIO_COMMIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
ENGINE_VERSION="$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "$SCRIPT_DIR/core/folio_engine/Cargo.toml" 2>/dev/null || echo "0.1.0")"

if [[ -n "${FOLIO_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FOLIO_VERSION" "$PLIST_PATH"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :FolioBuildChannel release" "$PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :FolioBuildChannel string release" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :FolioCommitSHA $COMMIT_SHA" "$PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :FolioCommitSHA string $COMMIT_SHA" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :FolioEngineVersion $ENGINE_VERSION" "$PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :FolioEngineVersion string $ENGINE_VERSION" "$PLIST_PATH"
rm -f "$SCRIPT_DIR/Folio.app/Contents/Resources/AppIcon-Dev.icns"
chmod 755 "$SCRIPT_DIR/Folio.app/Contents/Resources/bin/folio"

# Re-sign bundle so macOS accepts the stamped Info.plist
SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign "-" "$SCRIPT_DIR/Folio.app"
else
  echo "Signing Folio.app with identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SCRIPT_DIR/Folio.app"
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH")"
echo "Built native macOS bundle at: $SCRIPT_DIR/Folio.app (v${APP_VERSION}, Build #${BUILD_NUM}, ${COMMIT_SHA}, Engine v${ENGINE_VERSION})"

# Install or refresh the `folio` CLI launcher in writable PATH directories (/usr/local/bin, ~/.local/bin)
for BIN_DIR in "/usr/local/bin" "$HOME/.local/bin"; do
  mkdir -p "$BIN_DIR" 2>/dev/null || true
  if [[ -w "$BIN_DIR" ]]; then
    rm -f "$BIN_DIR/folio"
    cp "$SCRIPT_DIR/Folio.app/Contents/Resources/bin/folio" "$BIN_DIR/folio"
    chmod 755 "$BIN_DIR/folio"
    echo "Installed 'folio' CLI command at: $BIN_DIR/folio"
  fi
done
