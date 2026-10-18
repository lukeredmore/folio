#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
    # Fallback when executed directly from bazel-bin/third_party/zed/
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    if [[ ! -d "${REPO_ROOT}/third_party/zed" && -d "/Users/lukeredmore/Developer/OpenType/.worktrees/bazel-monorepo/third_party/zed" ]]; then
        REPO_ROOT="/Users/lukeredmore/Developer/OpenType/.worktrees/bazel-monorepo"
    fi
fi

ZED_UPSTREAM_DIR="${REPO_ROOT}/third_party/zed/upstream"
PATCH_FILE="${REPO_ROOT}/third_party/zed/patches/0002-real-zed-editor-opentype-wysiwyg.patch"
ZED_COMMIT="56934ec0560bce8929025497411de7f5322fb6ca"

if [[ ! -d "${ZED_UPSTREAM_DIR}/.git" ]]; then
    echo "[OpenType] Cloning upstream zed-industries/zed (${ZED_COMMIT})..."
    git clone --depth 1 https://github.com/zed-industries/zed.git "${ZED_UPSTREAM_DIR}"
    git -C "${ZED_UPSTREAM_DIR}" fetch --depth 1 origin "${ZED_COMMIT}"
    git -C "${ZED_UPSTREAM_DIR}" checkout "${ZED_COMMIT}"
    echo "[OpenType] Applying OpenType Markdown WYSIWYG patch to Zed crates/editor..."
    git -C "${ZED_UPSTREAM_DIR}" apply "${PATCH_FILE}"
fi

export PATH="${HOME}/.cargo/bin:${PATH}:/opt/local/bin"

echo "[OpenType] Ensuring Zed IDE with OpenType Markdown WYSIWYG mod is up to date..."
(cd "${ZED_UPSTREAM_DIR}" && cargo build -p zed)

ZED_BIN="${ZED_UPSTREAM_DIR}/target/debug/zed"
echo "[OpenType] Launching Zed IDE with OpenType Markdown WYSIWYG mod..."
exec "${ZED_BIN}" "$@"
