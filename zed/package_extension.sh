#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXT_DIR="${SCRIPT_DIR}/folio_zed_extension"
WASM_MANIFEST="${EXT_DIR}/wasm/Cargo.toml"
WASM_TARGET_DIR="${REPO_ROOT}/target/wasm-extension"

OUTPUT_ARCHIVE="${REPO_ROOT}/folio-markdown-outline.tar.gz"
VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_ARCHIVE="$2"
            shift 2
            ;;
        --version)
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

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

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/folio-zed-ext-pkg.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT

mkdir -p "${STAGE_DIR}/languages/markdown"
cp "${EXT_DIR}/extension.toml" "${STAGE_DIR}/extension.toml"
if [[ -n "${VERSION_OVERRIDE}" ]]; then
    python3 - "${STAGE_DIR}/extension.toml" "${VERSION_OVERRIDE}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
text = re.sub(r'^version\s*=\s*"[^"]+"', f'version = "{version}"', text, count=1, flags=re.M)
path.write_text(text)
PY
fi

cp "${WASM_ARTIFACT}" "${STAGE_DIR}/extension.wasm"
cp "${EXT_DIR}/languages/markdown/config.toml" "${STAGE_DIR}/languages/markdown/config.toml"
cp "${EXT_DIR}/languages/markdown/outline.scm" "${STAGE_DIR}/languages/markdown/outline.scm"

mkdir -p "$(dirname "${OUTPUT_ARCHIVE}")"
rm -f "${OUTPUT_ARCHIVE}"
COPYFILE_DISABLE=1 tar -czf "${OUTPUT_ARCHIVE}" -C "${STAGE_DIR}" \
    extension.toml \
    extension.wasm \
    languages

python3 - "${OUTPUT_ARCHIVE}" <<'PY'
import sys, tarfile
archive_path = sys.argv[1]
with tarfile.open(archive_path, "r:gz") as tf:
    names = set(tf.getnames())
    for required in ("extension.toml", "extension.wasm", "languages/markdown/config.toml", "languages/markdown/outline.scm"):
        if required not in names:
            raise SystemExit(f"Error: packaged archive missing {required} (found: {sorted(names)})")
    wasm_bytes = tf.extractfile("extension.wasm").read()
    if not wasm_bytes.startswith(b"\x00asm"):
        raise SystemExit("Error: extension.wasm does not have a valid WebAssembly header")
    if b"zed:api-version" not in wasm_bytes:
        raise SystemExit("Error: extension.wasm is missing the zed:api-version custom section")
PY

echo "Packaged and verified Folio Zed extension archive at ${OUTPUT_ARCHIVE}"
