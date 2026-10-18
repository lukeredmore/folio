#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./tools/bazel build //:FolioApp

echo "Built native macOS bundle at: $SCRIPT_DIR/Folio.app"
