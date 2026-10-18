#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

bazel build //:FolioApp

BUILT_APP="$SCRIPT_DIR/bazel-bin/macos/FolioApp/FolioApp_archive-root/Folio.app"
rm -rf "$SCRIPT_DIR/Folio.app"
cp -R "$BUILT_APP" "$SCRIPT_DIR/Folio.app"
chmod -R u+w "$SCRIPT_DIR/Folio.app"

echo "Built native macOS bundle at: $SCRIPT_DIR/Folio.app"
