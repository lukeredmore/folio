#!/usr/bin/env bash
# Installs the packaged extension archive into Zed. Run with: bazel run //:install_zed_extension
set -euo pipefail

ARCHIVE="$1"
ZED_EXTENSIONS_DIR="${ZED_EXTENSIONS_DIR:-${HOME}/Library/Application Support/Zed/extensions}"
INSTALL_DIR="${ZED_EXTENSIONS_DIR}/installed/folio-markdown-outline"

mkdir -p "${INSTALL_DIR}"
tar -xmzf "${ARCHIVE}" -C "${INSTALL_DIR}"

# Zed rebuilds its extension index on launch or reload when index.json is missing.
rm -f "${ZED_EXTENSIONS_DIR}/index.json"

VERSION="$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "${INSTALL_DIR}/extension.toml")"
echo "Installed Folio Markdown & LaTeX extension v${VERSION} to:"
echo "   ${INSTALL_DIR}"
echo "Open a .md file in Zed and run 'markdown: open preview' (Cmd-K V / Cmd-Shift-V)."
