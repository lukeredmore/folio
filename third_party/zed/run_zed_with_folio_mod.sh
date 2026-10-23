#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-$(python3 -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')}"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

BUILD_SCRIPT="${REPO_ROOT}/third_party/zed/build_moddable_zed.sh"
PATCH_FILE="${REPO_ROOT}/third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
EXTENSION_DIR="${REPO_ROOT}/zed/folio_zed_extension"
PROFILE="${FOLIO_ZED_PROFILE:-debug}"
CACHE_ROOT="${FOLIO_MODDABLE_ZED_CACHE_ROOT:-${HOME}/.cache/folio/moddable-zed}"

COMMON_GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "${COMMON_GIT_DIR}" ]]; then
    MAIN_REPO_ROOT="$(cd "${REPO_ROOT}" && cd "${COMMON_GIT_DIR}/.." && pwd)"
fi

export PATH="${HOME}/.cargo/bin:${PATH}:/opt/local/bin:/usr/local/bin"

MODDABLE_ZED_KEY="$("${BUILD_SCRIPT}" --print-key "${PATCH_FILE}" "${PROFILE}")"
CACHE_DIR="${CACHE_ROOT}/${MODDABLE_ZED_KEY}"
CACHED_TAR="${CACHE_DIR}/moddable_zed_bundle.tar"
EXTRACTED_DIR="${CACHE_DIR}/extracted"

if [[ "${FOLIO_FORCE_REBUILD_MODDABLE_ZED:-0}" == "1" || ! -x "${EXTRACTED_DIR}/zed" || ! -s "${EXTRACTED_DIR}/zed" ]]; then
    "${BUILD_SCRIPT}" "${CACHED_TAR}" "${PATCH_FILE}" "${PROFILE}"
    TMP_EXTRACT="${CACHE_DIR}/extracted.tmp.$$"
    rm -rf "${TMP_EXTRACT}"
    mkdir -p "${TMP_EXTRACT}"
    tar -xf "${CACHED_TAR}" -C "${TMP_EXTRACT}"
    rm -rf "${EXTRACTED_DIR}"
    mv "${TMP_EXTRACT}" "${EXTRACTED_DIR}"
fi

if ! codesign -v "${EXTRACTED_DIR}/zed" >/dev/null 2>&1; then
    codesign --force --sign - "${EXTRACTED_DIR}/zed"
fi
if [[ -x "${EXTRACTED_DIR}/cli" ]] && ! codesign -v "${EXTRACTED_DIR}/cli" >/dev/null 2>&1; then
    codesign --force --sign - "${EXTRACTED_DIR}/cli"
fi

ZED_BIN="${EXTRACTED_DIR}/zed"
ZED_CLI_BIN="${EXTRACTED_DIR}/cli"
FOLIO_CLI_WRAPPER="${EXTRACTED_DIR}/folio"
DEV_ICON_PATH="${REPO_ROOT}/macos/FolioApp/AppIcon-Dev.icns"
DEFAULT_WORKSPACE="${MAIN_REPO_ROOT:-${REPO_ROOT}}"
CALLER_CWD="${BUILD_WORKING_DIRECTORY:-$(pwd)}"

ZED_ARCH="$(lipo -archs "${ZED_BIN}" 2>/dev/null | awk '{print $1}' || uname -m)"
BAZEL_DYLIB="${REPO_ROOT}/bazel-bin/zed/folio_zed_mod/libfolio_zed_mod.dylib"
BAZEL_DYLIB_ARCH=""
if [[ -f "${BAZEL_DYLIB}" ]]; then
    BAZEL_DYLIB_ARCH="$(lipo -archs "${BAZEL_DYLIB}" 2>/dev/null | awk '{print $1}' || true)"
fi

if [[ -f "${BAZEL_DYLIB}" && "${BAZEL_DYLIB_ARCH}" == "${ZED_ARCH}" && "${FOLIO_PREFER_CARGO_DYLIB:-0}" != "1" ]]; then
    DYLIB_PATH="${BAZEL_DYLIB}"
else
    (cd "${REPO_ROOT}" && cargo build -q -p folio_zed_mod)
    DYLIB_PATH="${REPO_ROOT}/target/debug/libfolio_zed_mod.dylib"
fi

cat > "${FOLIO_CLI_WRAPPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ZED_CLI_BIN="${ZED_CLI_BIN}"
ZED_BIN="${ZED_BIN}"
export FOLIO_DEV_ICON_PATH="${DEV_ICON_PATH}"
export FOLIO_DEFAULT_WORKSPACE="${DEFAULT_WORKSPACE}"
export FOLIO_ZED_MOD_DYLIB_PATH="${DYLIB_PATH}"
export FOLIO_BUILTIN_EXTENSION_DIR="${EXTENSION_DIR}"

# If the caller already passed --zed, forward arguments directly.
for arg in "\$@"; do
  case "\$arg" in
    --zed|--zed=*)
      exec -a folio "\${ZED_CLI_BIN}" "\$@"
      ;;
  esac
done

exec -a folio "\${ZED_CLI_BIN}" --zed "\${ZED_BIN}" "\$@"
EOF
chmod +x "${FOLIO_CLI_WRAPPER}"

install_folio_cli_link() {
    local target_dir="$1"
    local link_path="${target_dir}/folio"
    if [[ -d "${target_dir}" && -w "${target_dir}" ]]; then
        ln -sf "${FOLIO_CLI_WRAPPER}" "${link_path}"
        echo "[Folio] Installed 'folio' CLI wrapper -> ${link_path}"
        return 0
    fi
    return 1
}

mkdir -p "${HOME}/.local/bin"
install_folio_cli_link "${HOME}/.local/bin" || true
install_folio_cli_link "/usr/local/bin" || true

resolve_caller_path() {
    local raw_path="$1"
    if [[ "${raw_path}" == ~* ]]; then
        raw_path="${HOME}${raw_path#\~}"
    fi
    if [[ "${raw_path}" != /* && "${raw_path}" != *://* && -e "${CALLER_CWD}/${raw_path}" ]]; then
        (cd "${CALLER_CWD}" && python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "${raw_path}")
    else
        printf '%s\n' "${raw_path}"
    fi
}

ZED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --open|--folder)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a folder or file path argument." >&2
                exit 1
            fi
            ZED_ARGS+=("$(resolve_caller_path "$2")")
            shift 2
            ;;
        --open=*|--folder=*)
            ZED_ARGS+=("$(resolve_caller_path "${1#*=}")")
            shift
            ;;
        --repo)
            ZED_ARGS+=("${DEFAULT_WORKSPACE}")
            shift
            ;;
        -h|--help)
            cat <<USAGE
Usage: bazel run //:zed_with_folio_mod [-- [OPTIONS] [PATHS...]]

Options:
  (no arguments)         Restore the previous Zed workspace/editor state (or open Folio repo on first run)
  <path>                 Open a specific folder or file in Folio Zed Dev
  --open <path>          Open a specific folder or file in Folio Zed Dev
  --repo                 Open the Folio repository root (${DEFAULT_WORKSPACE})
USAGE
            exec "${ZED_BIN}" --help
            ;;
        -*)
            ZED_ARGS+=("$1")
            shift
            ;;
        *)
            ZED_ARGS+=("$(resolve_caller_path "$1")")
            shift
            ;;
    esac
done

export FOLIO_DEV_ICON_PATH="${DEV_ICON_PATH}"
export FOLIO_DEFAULT_WORKSPACE="${DEFAULT_WORKSPACE}"
export FOLIO_ZED_MOD_DYLIB_PATH="${DYLIB_PATH}"
export FOLIO_BUILTIN_EXTENSION_DIR="${EXTENSION_DIR}"

echo "[Folio] Launching Zed IDE (${MODDABLE_ZED_KEY}) with Folio Markdown WYSIWYG dylib..."
if [[ ${#ZED_ARGS[@]} -eq 0 ]]; then
    exec "${ZED_BIN}"
else
    exec "${ZED_BIN}" "${ZED_ARGS[@]}"
fi
