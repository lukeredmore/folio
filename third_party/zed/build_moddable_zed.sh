#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-$(python3 -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')}"
PINNED_ZED_COMMIT="56934ec0560bce8929025497411de7f5322fb6ca"
GITHUB_REPO="${FOLIO_REPOSITORY:-lukeredmore/folio}"
CACHE_ROOT="${FOLIO_MODDABLE_ZED_CACHE_ROOT:-${HOME}/.cache/folio/moddable-zed}"

compute_key() {
  local patch_path="$1"
  local profile="$2"
  local patch_sha
  patch_sha="$(shasum -a 256 "$patch_path" | awk '{print substr($1, 1, 16)}')"
  printf '%s-%s-%s\n' "${PINNED_ZED_COMMIT:0:12}" "$patch_sha" "$profile"
}

if [[ "${1:-}" == "--print-key" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 --print-key <patch_file> [profile]" >&2
    exit 1
  fi
  REAL_PATCH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$2")"
  PROFILE="${3:-${FOLIO_ZED_PROFILE:-debug}}"
  compute_key "$REAL_PATCH" "$PROFILE"
  exit 0
fi

if [[ "${1:-}" == "--publish-release" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 --publish-release <patch_file> [profile]" >&2
    exit 1
  fi
  REAL_PATCH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$2")"
  PROFILE="${3:-${FOLIO_ZED_PROFILE:-debug}}"
  MODDABLE_ZED_KEY="$(compute_key "$REAL_PATCH" "$PROFILE")"
  CACHE_DIR="${CACHE_ROOT}/${MODDABLE_ZED_KEY}"
  CACHED_TAR="${CACHE_DIR}/moddable_zed_bundle.tar"
  if [[ ! -s "$CACHED_TAR" ]]; then
    "$0" "$CACHED_TAR" "$REAL_PATCH" "$PROFILE"
  fi
  TMP_ZST="$(mktemp -d)/moddable_zed_bundle.tar.zst"
  zstd -3 -q -f "$CACHED_TAR" -o "$TMP_ZST"
  RELEASE_TAG="moddable-zed-${MODDABLE_ZED_KEY}"
  echo "[Moddable Zed] Publishing $TMP_ZST to GitHub release $RELEASE_TAG ($GITHUB_REPO)..."
  gh release delete "$RELEASE_TAG" --repo "$GITHUB_REPO" --cleanup-tag --yes 2>/dev/null || true
  gh release create "$RELEASE_TAG" "$TMP_ZST" \
    --repo "$GITHUB_REPO" \
    --title "Moddable Zed Base Bundle (${MODDABLE_ZED_KEY})" \
    --notes "Prebuilt Moddable Zed base bundle for commit \`${PINNED_ZED_COMMIT}\` and patch SHA \`${MODDABLE_ZED_KEY}\` (profile: \`${PROFILE}\`). Used by Bazel and local dev to avoid a 100+ GB local Zed checkout." \
    --prerelease
  rm -rf "$(dirname "$TMP_ZST")"
  exit 0
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <out_tar> <patch_file> [profile]" >&2
  exit 1
fi

OUT_TAR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1")"
REAL_PATCH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$2")"
PROFILE="${3:-${FOLIO_ZED_PROFILE:-debug}}"

MODDABLE_ZED_KEY="$(compute_key "$REAL_PATCH" "$PROFILE")"
CACHE_DIR="${CACHE_ROOT}/${MODDABLE_ZED_KEY}"
CACHED_TAR="${CACHE_DIR}/moddable_zed_bundle.tar"
RELEASE_TAG="moddable-zed-${MODDABLE_ZED_KEY}"

# 1. Check local content-addressed Moddable Zed bundle cache (~/.cache/folio/moddable-zed/<key>)
if [[ "${FOLIO_FORCE_REBUILD_MODDABLE_ZED:-0}" != "1" && -s "$CACHED_TAR" ]]; then
  echo "[Moddable Zed] Reusing local cached bundle ($MODDABLE_ZED_KEY) -> $OUT_TAR"
  if [[ "$OUT_TAR" != "$CACHED_TAR" ]]; then
    mkdir -p "$(dirname "$OUT_TAR")"
    cp "$CACHED_TAR" "$OUT_TAR"
  fi
  exit 0
fi

# 2. Try downloading prebuilt Moddable Zed bundle from GitHub Releases (0 GB local Zed build needed)
if [[ "${FOLIO_FORCE_REBUILD_MODDABLE_ZED:-0}" != "1" && "${FOLIO_BUILD_MODDABLE_ZED_FROM_SOURCE:-0}" != "1" ]]; then
  DL_DIR="$(mktemp -d)"
  DL_ZST="${DL_DIR}/moddable_zed_bundle.tar.zst"
  DOWNLOADED=0
  if command -v gh >/dev/null 2>&1; then
    if gh release download "$RELEASE_TAG" --repo "$GITHUB_REPO" --pattern "moddable_zed_bundle.tar.zst" --dir "$DL_DIR" --clobber 2>/dev/null; then
      DOWNLOADED=1
    fi
  fi
  if [[ "$DOWNLOADED" -eq 0 ]] && command -v curl >/dev/null 2>&1; then
    RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/moddable_zed_bundle.tar.zst"
    if curl -fsSL "$RELEASE_URL" -o "$DL_ZST" 2>/dev/null; then
      DOWNLOADED=1
    fi
  fi
  if [[ "$DOWNLOADED" -eq 1 && -s "$DL_ZST" ]]; then
    echo "[Moddable Zed] Downloaded prebuilt bundle ($RELEASE_TAG) from GitHub Releases"
    mkdir -p "$CACHE_DIR" "$(dirname "$OUT_TAR")"
    zstd -d -q -f "$DL_ZST" -o "$CACHED_TAR"
    rm -rf "$DL_DIR"
    if [[ "$OUT_TAR" != "$CACHED_TAR" ]]; then
      cp "$CACHED_TAR" "$OUT_TAR"
    fi
    exit 0
  fi
  rm -rf "$DL_DIR"
fi

# 3. Fallback: Build Moddable Zed from source
REPO_ROOT="$(cd "$(dirname "$REAL_PATCH")/../../.." && pwd)"
ZED_DIR="$REPO_ROOT/third_party/zed/upstream"

export PATH="${HOME}/.cargo/bin:${PATH}:/opt/local/bin:/usr/local/bin"

COMMON_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_GIT_DIR" ]]; then
  MAIN_REPO_ROOT="$(cd "$REPO_ROOT" && cd "$COMMON_GIT_DIR/.." && pwd)"
else
  MAIN_REPO_ROOT="$REPO_ROOT"
fi
MAIN_ZED_DIR="$MAIN_REPO_ROOT/third_party/zed/upstream"

if [[ ! -e "$ZED_DIR/.git" ]]; then
  mkdir -p "$(dirname "$ZED_DIR")"
  if [[ -e "$MAIN_ZED_DIR/.git" && "$MAIN_ZED_DIR" != "$ZED_DIR" ]]; then
    echo "[Moddable Zed] Creating isolated Zed worktree from $MAIN_ZED_DIR at $PINNED_ZED_COMMIT..."
    git -C "$MAIN_ZED_DIR" worktree prune || true
    git -C "$MAIN_ZED_DIR" worktree add --detach "$ZED_DIR" "$PINNED_ZED_COMMIT"
  else
    echo "[Moddable Zed] Cloning upstream Zed repository into $ZED_DIR at $PINNED_ZED_COMMIT..."
    git init "$ZED_DIR"
    git -C "$ZED_DIR" remote add origin https://github.com/zed-industries/zed.git
    git -C "$ZED_DIR" fetch --depth 1 origin "$PINNED_ZED_COMMIT"
    git -C "$ZED_DIR" checkout --detach FETCH_HEAD
  fi
fi

if [[ -d "$MAIN_ZED_DIR/target" && ! -e "$ZED_DIR/target" ]]; then
  ln -s "$MAIN_ZED_DIR/target" "$ZED_DIR/target"
fi

echo "[Moddable Zed] Applying Folio host patch ($MODDABLE_ZED_KEY) to upstream Zed..."
git -C "$ZED_DIR" checkout -- . || true
git -C "$ZED_DIR" clean -fd || true
git -C "$ZED_DIR" apply "$REAL_PATCH"

TARGET_BASE="${CARGO_TARGET_DIR:-$ZED_DIR/target}"

if [[ "$PROFILE" == "debug" ]]; then
  TARGET_SUBDIR="debug"
  # Use slim Cargo profile flags (~12 GB instead of 103 GB) on fresh builds or when FOLIO_SLIM_ZED_CARGO=1
  if [[ "${FOLIO_SLIM_ZED_CARGO:-auto}" == "1" || ( "${FOLIO_SLIM_ZED_CARGO:-auto}" == "auto" && ! -d "$TARGET_BASE/debug/deps" ) ]]; then
    CARGO_PROFILE_ARGS=(
      --config 'profile.dev.debug=0'
      --config 'profile.dev.strip="debuginfo"'
      --config 'profile.dev.incremental=false'
      --config 'profile.dev.package.markdown.debug=1'
      --config 'profile.dev.package.zed.debug=1'
    )
  else
    CARGO_PROFILE_ARGS=()
  fi
elif [[ "$PROFILE" == "release" ]]; then
  CARGO_PROFILE_ARGS=(--release)
  TARGET_SUBDIR="release"
else
  CARGO_PROFILE_ARGS=(--profile "$PROFILE")
  TARGET_SUBDIR="$PROFILE"
fi

ZED_BIN="$TARGET_BASE/$TARGET_SUBDIR/zed"
CLI_BIN="$TARGET_BASE/$TARGET_SUBDIR/cli"

if [[ "${FOLIO_ZED_SKIP_CARGO_BUILD:-0}" != "1" || ! -x "$ZED_BIN" ]]; then
  if [[ -f "$TARGET_BASE/.folio_source_hashes.json" || "${CI:-}" == "true" || "${FOLIO_SYNC_CARGO_MTIMES:-0}" == "1" ]]; then
    python3 "$REPO_ROOT/scripts/sync_cargo_mtimes.py" restore "$REPO_ROOT" "$TARGET_BASE"
  fi
  echo "[Moddable Zed] Building vanilla Moddable Zed binaries (profile: $PROFILE)..."
  (
    cd "$ZED_DIR"
    cargo build ${CARGO_PROFILE_ARGS[@]+"${CARGO_PROFILE_ARGS[@]}"} --package zed --package cli --bin zed --bin cli
  )
  if [[ -f "$TARGET_BASE/.folio_source_hashes.json" || "${CI:-}" == "true" || "${FOLIO_SYNC_CARGO_MTIMES:-0}" == "1" ]]; then
    python3 "$REPO_ROOT/scripts/sync_cargo_mtimes.py" record "$REPO_ROOT" "$TARGET_BASE"
  fi
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp "$ZED_BIN" "$STAGE_DIR/zed"
chmod +x "$STAGE_DIR/zed"
strip -x "$STAGE_DIR/zed" -o "$STAGE_DIR/zed.stripped" 2>/dev/null && mv "$STAGE_DIR/zed.stripped" "$STAGE_DIR/zed" || true
codesign --force --sign - "$STAGE_DIR/zed"
if [[ ! -s "$STAGE_DIR/zed" ]]; then
  echo "Error: staged Zed binary is empty" >&2
  exit 1
fi

if [[ -x "$CLI_BIN" ]]; then
  cp "$CLI_BIN" "$STAGE_DIR/cli"
  chmod +x "$STAGE_DIR/cli"
  strip -x "$STAGE_DIR/cli" -o "$STAGE_DIR/cli.stripped" 2>/dev/null && mv "$STAGE_DIR/cli.stripped" "$STAGE_DIR/cli" || true
  codesign --force --sign - "$STAGE_DIR/cli"
fi

if [[ -f "$ZED_DIR/crates/zed/resources/Document.icns" ]]; then
  cp "$ZED_DIR/crates/zed/resources/Document.icns" "$STAGE_DIR/Document.icns"
fi

if [[ -f "$ZED_DIR/crates/zed/resources/zed.entitlements" ]]; then
  cp "$ZED_DIR/crates/zed/resources/zed.entitlements" "$STAGE_DIR/zed.entitlements"
fi

mkdir -p "$CACHE_DIR" "$(dirname "$OUT_TAR")"
TMP_TAR="${CACHED_TAR}.tmp.$$"
COPYFILE_DISABLE=1 tar -cf "$TMP_TAR" -C "$STAGE_DIR" .
mv -f "$TMP_TAR" "$CACHED_TAR"
if [[ "$OUT_TAR" != "$CACHED_TAR" ]]; then
  cp "$CACHED_TAR" "$OUT_TAR"
fi

if [[ "${FOLIO_CLEAN_ZED_TARGET_AFTER_BUILD:-0}" == "1" ]]; then
  echo "[Moddable Zed] Cleaning $TARGET_BASE after caching bundle..."
  rm -rf "$TARGET_BASE"
fi

echo "[Moddable Zed] Packaged cacheable Moddable Zed artifact ($MODDABLE_ZED_KEY) -> $OUT_TAR"
