#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

./build_app.sh

DMG_PATH="$SCRIPT_DIR/Folio.dmg"
rm -f "$DMG_PATH"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$SCRIPT_DIR/Folio.app" "$STAGING_DIR/Folio.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Folio" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "Signing Folio.dmg with identity: $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  echo "Submitting Folio.dmg to Apple Notary Service..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "Packaged DMG: $DMG_PATH (SHA-256: $DMG_SHA256)"
