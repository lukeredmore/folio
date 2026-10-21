#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$SCRIPT_DIR"

DMG_PATH="$SCRIPT_DIR/Folio-Zed.dmg"
HASH_FILE="$SCRIPT_DIR/.folio_zed_dmg_graph_hash"
GRAPH_HASH="${FOLIO_ZED_GRAPH_HASH:-$("$SCRIPT_DIR/scripts/bazel_target_hash.sh" //:package_zed_dmg 2>/dev/null || true)}"

if [[ "${FOLIO_FORCE_REBUILD:-0}" != "1" && -n "$GRAPH_HASH" && -f "$DMG_PATH" && -f "$HASH_FILE" ]]; then
  if [[ "$(cat "$HASH_FILE")" == "$GRAPH_HASH" ]]; then
    DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    echo "Folio-Zed.dmg is up to date for Bazel graph hash ${GRAPH_HASH:0:12} (SHA-256: $DMG_SHA256); skipping rebuild."
    exit 0
  fi
fi

./build_zed_app.sh

rm -f "$DMG_PATH"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$SCRIPT_DIR/Folio Zed.app" "$STAGING_DIR/Folio Zed.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Folio Zed" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "Signing Folio-Zed.dmg with identity: $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  echo "Submitting Folio-Zed.dmg to Apple Notary Service..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

if [[ -n "$GRAPH_HASH" ]]; then
  printf '%s\n' "$GRAPH_HASH" > "$HASH_FILE"
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "Packaged DMG: $DMG_PATH (SHA-256: $DMG_SHA256)"
