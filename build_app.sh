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
QUEUE_FILE="$HOME/Library/Application Support/Folio/cli_open_requests.txt"
for BIN_DIR in "/usr/local/bin" "$HOME/.local/bin"; do
  mkdir -p "$BIN_DIR" 2>/dev/null || true
  if [[ -w "$BIN_DIR" ]]; then
    cat > "$BIN_DIR/folio" <<EOF
#!/usr/bin/env bash
# Folio CLI launcher — opens Markdown files and folders in Folio.app
set -euo pipefail
QUEUE_FILE="${QUEUE_FILE}"
FALLBACK_APP="$SCRIPT_DIR/Folio.app"

if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    echo "Usage: folio [path ...]"
    echo "Open files or folders in Folio."
    exit 0
fi
if [[ "\${1:-}" == "-v" || "\${1:-}" == "--version" ]]; then
    echo "folio ${APP_VERSION}"
    exit 0
fi

resolve_app_bundle() {
    for candidate in "\${FOLIO_APP_PATH:-}" "/Applications/Folio.app" "\$HOME/Applications/Folio.app" "\${FALLBACK_APP}"; do
        if [[ -n "\${candidate}" && -d "\${candidate}" ]]; then
            echo "\${candidate}"
            return 0
        fi
    done
    local found
    found="\$(mdfind "kMDItemCFBundleIdentifier == 'app.folio.macos'" 2>/dev/null | head -n 1 || true)"
    if [[ -n "\${found}" && -d "\${found}" ]]; then
        echo "\${found}"
        return 0
    fi
    return 1
}

ABS_PATHS=()
for arg in "\$@"; do
    [[ "\${arg}" == -* ]] && continue
    if [[ -d "\${arg}" ]]; then
        ABS_PATHS+=("\$(cd "\${arg}" && pwd -P)")
    else
        if [[ ! -e "\${arg}" ]]; then
            mkdir -p "\$(dirname "\${arg}")"
            touch "\${arg}"
        fi
        dir_part="\$(cd "\$(dirname "\${arg}")" && pwd -P)"
        ABS_PATHS+=("\${dir_part}/\$(basename "\${arg}")")
    fi
done

if (( \${#ABS_PATHS[@]} > 0 )); then
    mkdir -p "\$(dirname "\${QUEUE_FILE}")"
    for p in "\${ABS_PATHS[@]}"; do
        printf '%s\n' "\${p}" >> "\${QUEUE_FILE}"
    done
fi

RUNNING_PIDS="\$(pgrep -x "Folio" 2>/dev/null || pgrep -x "FolioApp" 2>/dev/null || true)"
if [[ -n "\${RUNNING_PIDS}" ]]; then
    for pid in \${RUNNING_PIDS}; do
        kill -USR1 "\${pid}" 2>/dev/null || true
    done
    osascript -e 'tell application "System Events" to set frontmost of every process whose name is "Folio" or name is "FolioApp" to true' >/dev/null 2>&1 || true
    exit 0
fi

if APP_BUNDLE="\$(resolve_app_bundle)"; then
    if (( \${#ABS_PATHS[@]} > 0 )); then
        open -a "\${APP_BUNDLE}" --args "\${ABS_PATHS[@]}"
    else
        open -a "\${APP_BUNDLE}"
    fi
else
    echo "folio: could not locate Folio.app. Move Folio.app to /Applications or set FOLIO_APP_PATH." >&2
    exit 1
fi
EOF
    chmod 755 "$BIN_DIR/folio"
    echo "Installed 'folio' CLI command at: $BIN_DIR/folio"
  fi
done
