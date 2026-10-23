#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROFILE="${FOLIO_ZED_PROFILE:-debug}"
BAZEL_MODE_ARGS=()
if [[ "$PROFILE" == "release" || "$PROFILE" == "release-fast" ]]; then
  BAZEL_MODE_ARGS=(-c opt)
fi

chmod +x "$SCRIPT_DIR/third_party/zed/build_moddable_zed.sh"

echo "Building Moddable Zed bundle + Folio Zed Mod dylib in parallel via Bazel (profile: $PROFILE)..."
bazel build "${BAZEL_MODE_ARGS[@]}" \
  //third_party/zed:moddable_zed_bundle \
  //zed/folio_zed_mod:folio_zed_mod_dylib \
  //zed/folio_zed_extension:extension_bundle

BUNDLE_TAR="$SCRIPT_DIR/bazel-bin/third_party/zed/moddable_zed_bundle.tar"
DYLIB_PATH="$SCRIPT_DIR/bazel-bin/zed/folio_zed_mod/libfolio_zed_mod.dylib"

MODDABLE_STAGE="$(mktemp -d)"
trap 'rm -rf "$MODDABLE_STAGE"' EXIT
tar -xf "$BUNDLE_TAR" -C "$MODDABLE_STAGE"

APP_BUNDLE="$SCRIPT_DIR/Folio Zed.app"
rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Frameworks" \
  "$APP_BUNDLE/Contents/Resources/builtin_extensions/folio-markdown-outline"

cp "$MODDABLE_STAGE/zed" "$APP_BUNDLE/Contents/MacOS/zed"
chmod +x "$APP_BUNDLE/Contents/MacOS/zed"

if [[ -x "$MODDABLE_STAGE/cli" ]]; then
  cp "$MODDABLE_STAGE/cli" "$APP_BUNDLE/Contents/MacOS/cli"
  chmod +x "$APP_BUNDLE/Contents/MacOS/cli"
fi

cp "$DYLIB_PATH" "$APP_BUNDLE/Contents/Frameworks/libfolio_zed_mod.dylib"
chmod +x "$APP_BUNDLE/Contents/Frameworks/libfolio_zed_mod.dylib"

cp "$SCRIPT_DIR/zed/folio_zed_extension/extension.toml" \
  "$APP_BUNDLE/Contents/Resources/builtin_extensions/folio-markdown-outline/extension.toml"
cp -R "$SCRIPT_DIR/zed/folio_zed_extension/languages" \
  "$APP_BUNDLE/Contents/Resources/builtin_extensions/folio-markdown-outline/languages"

if [[ -f "$SCRIPT_DIR/macos/FolioApp/AppIcon.icns" ]]; then
  cp "$SCRIPT_DIR/macos/FolioApp/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$MODDABLE_STAGE/Document.icns" ]]; then
  cp "$MODDABLE_STAGE/Document.icns" "$APP_BUNDLE/Contents/Resources/Document.icns"
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
if [[ -f "$MODDABLE_STAGE/zed.entitlements" ]]; then
  sed '/com.apple.developer.associated-domains/,+1d' "$MODDABLE_STAGE/zed.entitlements" > "$ENTITLEMENTS_PATH"
fi

SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign "-" "$APP_BUNDLE/Contents/Frameworks/libfolio_zed_mod.dylib"
  if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    codesign --force --deep --entitlements "$ENTITLEMENTS_PATH" --sign "-" "$APP_BUNDLE"
  else
    codesign --force --deep --sign "-" "$APP_BUNDLE"
  fi
else
  echo "Signing Folio Zed.app with identity: $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libfolio_zed_mod.dylib"
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
