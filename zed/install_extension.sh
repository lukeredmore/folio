#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXT_DIR="${SCRIPT_DIR}/folio_zed_extension"
WASM_MANIFEST="${EXT_DIR}/wasm/Cargo.toml"
WASM_TARGET_DIR="${REPO_ROOT}/target/wasm-extension"

ZED_EXTENSIONS_DIR="${ZED_EXTENSIONS_DIR:-${HOME}/Library/Application Support/Zed/extensions}"
INSTALL_DIR="${ZED_EXTENSIONS_DIR}/installed/folio-markdown-outline"

if ! rustup target list --installed | grep -q '^wasm32-wasip2$'; then
    echo "Installing Rust target wasm32-wasip2..."
    rustup target add wasm32-wasip2
fi

echo "Building Folio Zed extension (wasm32-wasip2)..."
cargo build \
    --manifest-path "${WASM_MANIFEST}" \
    --target wasm32-wasip2 \
    --release \
    --target-dir "${WASM_TARGET_DIR}"

WASM_ARTIFACT="${WASM_TARGET_DIR}/wasm32-wasip2/release/folio_markdown_outline.wasm"
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
