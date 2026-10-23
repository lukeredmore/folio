#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <out_tar> <patch_file> [profile]" >&2
  exit 1
fi

OUT_TAR="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1")"
REAL_PATCH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$2")"
PROFILE="${3:-${FOLIO_ZED_PROFILE:-debug}}"

REPO_ROOT="$(cd "$(dirname "$REAL_PATCH")/../.." && pwd)"
ZED_DIR="$REPO_ROOT/third_party/zed/upstream"
PINNED_ZED_COMMIT="56934ec0560bce8929025497411de7f5322fb6ca"

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

if ! grep -q "folio_dylib" "$ZED_DIR/crates/markdown/src/markdown.rs" 2>/dev/null; then
  echo "[Moddable Zed] Applying Folio host patch to upstream Zed..."
  git -C "$ZED_DIR" checkout -- . || true
  git -C "$ZED_DIR" clean -fd || true
  git -C "$ZED_DIR" apply "$REAL_PATCH"
fi

if [[ "$PROFILE" == "debug" ]]; then
  CARGO_PROFILE_ARGS=()
  TARGET_SUBDIR="debug"
elif [[ "$PROFILE" == "release" ]]; then
  CARGO_PROFILE_ARGS=(--release)
  TARGET_SUBDIR="release"
else
  CARGO_PROFILE_ARGS=(--profile "$PROFILE")
  TARGET_SUBDIR="$PROFILE"
fi

TARGET_BASE="${CARGO_TARGET_DIR:-$ZED_DIR/target}"
ZED_BIN="$TARGET_BASE/$TARGET_SUBDIR/zed"
CLI_BIN="$TARGET_BASE/$TARGET_SUBDIR/cli"

if [[ "${FOLIO_ZED_SKIP_CARGO_BUILD:-0}" != "1" || ! -x "$ZED_BIN" ]]; then
  if [[ -f "$TARGET_BASE/.folio_source_hashes.json" || "${CI:-}" == "true" || "${FOLIO_SYNC_CARGO_MTIMES:-0}" == "1" ]]; then
    python3 "$REPO_ROOT/scripts/sync_cargo_mtimes.py" restore "$REPO_ROOT" "$TARGET_BASE"
  fi
  echo "[Moddable Zed] Building vanilla Moddable Zed binaries (profile: $PROFILE)..."
  (
    cd "$ZED_DIR"
    cargo build "${CARGO_PROFILE_ARGS[@]}" --package zed --package cli --bin zed --bin cli
  )
  if [[ -f "$TARGET_BASE/.folio_source_hashes.json" || "${CI:-}" == "true" || "${FOLIO_SYNC_CARGO_MTIMES:-0}" == "1" ]]; then
    python3 "$REPO_ROOT/scripts/sync_cargo_mtimes.py" record "$REPO_ROOT" "$TARGET_BASE"
  fi
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp "$ZED_BIN" "$STAGE_DIR/zed"
chmod +x "$STAGE_DIR/zed"

if [[ -x "$CLI_BIN" ]]; then
  cp "$CLI_BIN" "$STAGE_DIR/cli"
  chmod +x "$STAGE_DIR/cli"
fi

if [[ -f "$ZED_DIR/crates/zed/resources/Document.icns" ]]; then
  cp "$ZED_DIR/crates/zed/resources/Document.icns" "$STAGE_DIR/Document.icns"
fi

if [[ -f "$ZED_DIR/crates/zed/resources/zed.entitlements" ]]; then
  cp "$ZED_DIR/crates/zed/resources/zed.entitlements" "$STAGE_DIR/zed.entitlements"
fi

mkdir -p "$(dirname "$OUT_TAR")"
COPYFILE_DISABLE=1 tar -cf "$OUT_TAR" -C "$STAGE_DIR" .
echo "[Moddable Zed] Packaged cacheable Moddable Zed artifact -> $OUT_TAR"
