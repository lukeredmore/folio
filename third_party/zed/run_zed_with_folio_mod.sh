#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
    # Fallback when executed directly from bazel-bin/third_party/zed/ or repo
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

ZED_UPSTREAM_DIR="${REPO_ROOT}/third_party/zed/upstream"
PATCH_FILE="${REPO_ROOT}/third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
ZED_COMMIT="56934ec0560bce8929025497411de7f5322fb6ca"

if [[ ! -e "${ZED_UPSTREAM_DIR}/.git" ]]; then
    COMMON_GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "${COMMON_GIT_DIR}" ]]; then
        MAIN_REPO_ROOT="$(cd "${REPO_ROOT}" && cd "${COMMON_GIT_DIR}/.." && pwd)"
        MAIN_ZED_UPSTREAM="${MAIN_REPO_ROOT}/third_party/zed/upstream"
        if [[ -e "${MAIN_ZED_UPSTREAM}/.git" && "${MAIN_REPO_ROOT}" != "${REPO_ROOT}" ]]; then
            echo "[Folio] Creating isolated Zed worktree in ${ZED_UPSTREAM_DIR} (sharing Cargo target cache)..."
            git -C "${MAIN_ZED_UPSTREAM}" worktree prune || true
            git -C "${MAIN_ZED_UPSTREAM}" worktree add --detach "${ZED_UPSTREAM_DIR}" "${ZED_COMMIT}"
            git -C "${ZED_UPSTREAM_DIR}" apply "${PATCH_FILE}"
            if [[ -d "${MAIN_ZED_UPSTREAM}/target" && ! -e "${ZED_UPSTREAM_DIR}/target" ]]; then
                ln -s "${MAIN_ZED_UPSTREAM}/target" "${ZED_UPSTREAM_DIR}/target"
            fi
        fi
    fi
fi

if [[ ! -e "${ZED_UPSTREAM_DIR}/.git" ]]; then
    echo "[Folio] Cloning upstream zed-industries/zed (${ZED_COMMIT})..."
    git clone --depth 1 https://github.com/zed-industries/zed.git "${ZED_UPSTREAM_DIR}"
    git -C "${ZED_UPSTREAM_DIR}" fetch --depth 1 origin "${ZED_COMMIT}"
    git -C "${ZED_UPSTREAM_DIR}" checkout "${ZED_COMMIT}"
    echo "[Folio] Applying Folio Markdown WYSIWYG patch to Zed crates/editor..."
    git -C "${ZED_UPSTREAM_DIR}" apply "${PATCH_FILE}"
fi

export PATH="${HOME}/.cargo/bin:${PATH}:/opt/local/bin"

echo "[Folio] Ensuring Zed IDE with Folio Markdown WYSIWYG mod and CLI are up to date..."
(cd "${ZED_UPSTREAM_DIR}" && cargo build -p zed -p cli)

ZED_BIN="${ZED_UPSTREAM_DIR}/target/debug/zed"
ZED_CLI_BIN="${ZED_UPSTREAM_DIR}/target/debug/cli"
FOLIO_CLI_WRAPPER="${ZED_UPSTREAM_DIR}/target/debug/folio"

cat > "${FOLIO_CLI_WRAPPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ZED_CLI_BIN="${ZED_CLI_BIN}"
ZED_BIN="${ZED_BIN}"

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

echo "[Folio] Launching Zed IDE with Folio Markdown WYSIWYG mod..."
exec "${ZED_BIN}" "$@"
