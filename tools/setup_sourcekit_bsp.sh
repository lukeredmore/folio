#!/usr/bin/env bash
# Runs the sourcekit-bazel-bsp setup script, which needs the macOS (BSD) sed, not GNU sed.
set -euo pipefail
PATH="/usr/bin:/bin:${PATH}" exec "$1"
