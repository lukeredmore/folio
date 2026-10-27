#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXT_DIR="${SCRIPT_DIR}/folio_zed_extension"

ZED_EXTENSIONS_DIR="${ZED_EXTENSIONS_DIR:-${HOME}/Library/Application Support/Zed/extensions}"
INSTALL_DIR="${ZED_EXTENSIONS_DIR}/installed/folio-markdown-outline"

echo "Building Folio Zed extension (wasm32-wasip2)..."
WASM_TARGET="//zed/folio_zed_extension/wasm:extension_wasm"
(cd "${REPO_ROOT}" && bazel build -c opt "${WASM_TARGET}")
WASM_ARTIFACT="${REPO_ROOT}/$(cd "${REPO_ROOT}" && bazel cquery -c opt --output=files "${WASM_TARGET}" 2>/dev/null)"
if [[ ! -f "${WASM_ARTIFACT}" ]]; then
    echo "Error: expected WASI component at ${WASM_ARTIFACT}" >&2
    exit 1
fi

echo "Installing extension into ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/languages/markdown"
cp "${EXT_DIR}/extension.toml" "${INSTALL_DIR}/extension.toml"
cp "${WASM_ARTIFACT}" "${INSTALL_DIR}/extension.wasm"
cp "${EXT_DIR}/languages/markdown/config.toml" "${INSTALL_DIR}/languages/markdown/config.toml"
cp "${EXT_DIR}/languages/markdown/outline.scm" "${INSTALL_DIR}/languages/markdown/outline.scm"

# Remove cached extensions/index.json so Zed rebuilds its extension index on launch/reload
rm -f "${ZED_EXTENSIONS_DIR}/index.json"

echo "✅ Installed Folio Markdown & LaTeX extension (v0.2.0, schema_version = 1) to:"
echo "   ${INSTALL_DIR}"
echo "Open any .md file in Zed and run 'markdown: open preview' (Cmd-K V / Cmd-Shift-V) to use the Folio WYSIWYG editor."
