#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./tools/bazel build //:opentype_macos_app

ZIP_PATH="$(./tools/bazel cquery --output=files //:opentype_macos_app 2>/dev/null | head -n 1)"
rm -rf "$SCRIPT_DIR/OpenType.app"
unzip -oq "$ZIP_PATH" -d "$SCRIPT_DIR"

echo "Built native macOS bundle at: $SCRIPT_DIR/OpenType.app"
