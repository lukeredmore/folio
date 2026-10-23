#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ZED_DIR="$SCRIPT_DIR/third_party/zed/upstream"
PATCH_0002="$SCRIPT_DIR/third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
PINNED_ZED_COMMIT="56934ec0560bce8929025497411de7f5322fb6ca"

MAIN_REPO_ROOT="$(cd "$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir)/.." && pwd)"
MAIN_ZED_DIR="$MAIN_REPO_ROOT/third_party/zed/upstream"

if [[ ! -e "$ZED_DIR/.git" ]]; then
  mkdir -p "$(dirname "$ZED_DIR")"
  if [[ -d "$MAIN_ZED_DIR/.git" && "$MAIN_ZED_DIR" != "$ZED_DIR" ]]; then
    echo "Creating isolated Zed upstream worktree from $MAIN_ZED_DIR at $PINNED_ZED_COMMIT..."
    git -C "$MAIN_ZED_DIR" worktree prune
    git -C "$MAIN_ZED_DIR" worktree add --detach "$ZED_DIR" "$PINNED_ZED_COMMIT"
  else
    echo "Cloning upstream Zed repository into $ZED_DIR at $PINNED_ZED_COMMIT..."
    git init "$ZED_DIR"
    git -C "$ZED_DIR" remote add origin https://github.com/zed-industries/zed.git
    git -C "$ZED_DIR" fetch --depth 1 origin "$PINNED_ZED_COMMIT"
    git -C "$ZED_DIR" checkout --detach FETCH_HEAD
  fi
fi

if [[ -d "$MAIN_ZED_DIR/target" && ! -e "$ZED_DIR/target" ]]; then
  ln -s "$MAIN_ZED_DIR/target" "$ZED_DIR/target"
fi

if ! grep -q "folio_zed_mod" "$ZED_DIR/crates/markdown/src/markdown.rs" 2>/dev/null; then
  echo "Applying Folio patch to upstream Zed..."
  git -C "$ZED_DIR" apply "$PATCH_0002"
fi

PROFILE="${FOLIO_ZED_PROFILE:-debug}"
if [[ "$PROFILE" == "debug" ]]; then
  CARGO_PROFILE_ARGS=()
  TARGET_SUBDIR="debug"
elif [[ "$PROFILE" == "release" ]]; then
  CARGO_PROFILE_ARGS=(--release)
  TARGET_SUBDIR="release"
else
  CARGO_PROFILE_ARGS=(--profile "$PROFILE")
  TARGET_SUBDIR="$PROFILE"
fi

TARGET_BASE="${CARGO_TARGET_DIR:-$ZED_DIR/target}"
ZED_BIN="$TARGET_BASE/$TARGET_SUBDIR/zed"
CLI_BIN="$TARGET_BASE/$TARGET_SUBDIR/cli"

if [[ "${FOLIO_ZED_SKIP_CARGO_BUILD:-0}" != "1" || ! -x "$ZED_BIN" ]]; then
  echo "Building Folio Zed binaries (profile: $PROFILE)..."
  (
    cd "$ZED_DIR"
    cargo build "${CARGO_PROFILE_ARGS[@]}" --package zed --package cli --bin zed --bin cli
  )
fi

APP_BUNDLE="$SCRIPT_DIR/Folio Zed.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$ZED_BIN" "$APP_BUNDLE/Contents/MacOS/zed"
chmod +x "$APP_BUNDLE/Contents/MacOS/zed"

if [[ -x "$CLI_BIN" ]]; then
  cp "$CLI_BIN" "$APP_BUNDLE/Contents/MacOS/cli"
  chmod +x "$APP_BUNDLE/Contents/MacOS/cli"
fi

if [[ -f "$SCRIPT_DIR/macos/FolioApp/AppIcon-Zed.icns" ]]; then
  cp "$SCRIPT_DIR/macos/FolioApp/AppIcon-Zed.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ZED_DIR/crates/zed/resources/Document.icns" ]]; then
  cp "$ZED_DIR/crates/zed/resources/Document.icns" "$APP_BUNDLE/Contents/Resources/Document.icns"
fi

APP_VERSION="${FOLIO_VERSION:-1.0.0}"
BUILD_NUM="${FOLIO_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COMMIT_SHA="${FOLIO_COMMIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
ENGINE_VERSION="$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "$SCRIPT_DIR/core/folio_engine/Cargo.toml" 2>/dev/null || echo "0.1.0")"
FOLIO_REPO="${FOLIO_REPOSITORY:-lukeredmore/folio}"

PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Folio Zed</string>
  <key>CFBundleExecutable</key>
  <string>zed</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.folio.zed</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Folio Zed</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUM}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>ZedReleaseChannel</key>
  <string>stable</string>
  <key>FolioBuildChannel</key>
  <string>release</string>
  <key>FolioCommitSHA</key>
  <string>${COMMIT_SHA}</string>
  <key>FolioEngineVersion</key>
  <string>${ENGINE_VERSION}</string>
  <key>FolioRepository</key>
  <string>${FOLIO_REPO}</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Zed URL</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>zed</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeIconFile</key>
      <string>Document</string>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.markdown</string>
        <string>public.folder</string>
        <string>public.plain-text</string>
        <string>public.text</string>
        <string>public.utf8-plain-text</string>
      </array>
    </dict>
  </array>
  <key>NSAppleEventsUsageDescription</key>
  <string>An application in Folio Zed wants to use AppleScript.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>An application in Folio Zed wants to use your microphone.</string>
  <key>NSCameraUsageDescription</key>
  <string>An application in Folio Zed wants to use the camera.</string>
</dict>
</plist>
EOF

ENTITLEMENTS_PATH="$APP_BUNDLE/Contents/Resources/zed.entitlements"
if [[ -f "$ZED_DIR/crates/zed/resources/zed.entitlements" ]]; then
  sed '/com.apple.developer.associated-domains/,+1d' "$ZED_DIR/crates/zed/resources/zed.entitlements" > "$ENTITLEMENTS_PATH"
fi

SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    codesign --force --deep --entitlements "$ENTITLEMENTS_PATH" --sign "-" "$APP_BUNDLE"
  else
    codesign --force --deep --sign "-" "$APP_BUNDLE"
  fi
else
  echo "Signing Folio Zed.app with identity: $SIGN_IDENTITY"
  if [[ -x "$APP_BUNDLE/Contents/MacOS/cli" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/cli"
  fi
  if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/zed"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  fi
fi

echo "Built Folio Zed macOS bundle at: $APP_BUNDLE (v${APP_VERSION}, Build #${BUILD_NUM}, ${COMMIT_SHA}, Engine v${ENGINE_VERSION})"
