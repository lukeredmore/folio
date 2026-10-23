#!/usr/bin/env python3
"""Synchronize source file mtimes with content hashes to preserve Cargo incremental caches in CI.

On fresh GitHub Actions runners, `actions/checkout` and `git clone`/`git apply` stamp all
checked-out source files in `third_party/zed/upstream`, `core/folio_engine`,
`third_party/cmark_gfm`, and `zed/` with the current wall-clock `mtime`. Because Cargo's
fingerprint check (`FsStatusOutdated`) compares source `mtime` against the `mtime` of
`target/<profile>/.fingerprint/<crate>/dep-*` from the restored cache, a fresh checkout
otherwise invalidates all 380+ workspace crates and triggers a ~50-minute rebuild.

Usage:
  python3 scripts/sync_cargo_mtimes.py restore <repo_root> <target_dir>
  python3 scripts/sync_cargo_mtimes.py record  <repo_root> <target_dir>
"""

import hashlib
import json
import os
import subprocess
import sys
import time

# Fixed past timestamp (2023-11-14T22:13:20Z) older than any cached Cargo `.fingerprint` artifact.
BASELINE_MTIME = 1700000000

TRACKED_DIRS = (
    "third_party/zed/upstream",
    "core/folio_engine",
    "third_party/cmark_gfm",
    "zed/folio_zed_mod",
    "zed/folio_zed_extension",
)

TRACKED_FILES = (
    "Cargo.toml",
    "Cargo.lock",
)

SKIP_DIR_NAMES = {".git", "target"}


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            digest.update(chunk)
    return digest.hexdigest()


def iter_source_files(repo_root: str):
    for rel_file in TRACKED_FILES:
        full_path = os.path.join(repo_root, rel_file)
        if os.path.isfile(full_path) and not os.path.islink(full_path):
            yield rel_file, full_path

    for rel_root in TRACKED_DIRS:
        root_path = os.path.join(repo_root, rel_root)
        if not os.path.isdir(root_path) or os.path.islink(root_path):
            continue
        for dirpath, dirnames, filenames in os.walk(root_path, topdown=True):
            dirnames[:] = [
                d
                for d in dirnames
                if d not in SKIP_DIR_NAMES
                and not os.path.islink(os.path.join(dirpath, d))
            ]
            for fname in filenames:
                full_path = os.path.join(dirpath, fname)
                if os.path.islink(full_path) or not os.path.isfile(full_path):
                    continue
                rel_path = os.path.relpath(full_path, repo_root).replace(os.sep, "/")
                yield rel_path, full_path


def clamp_directories_and_git_refs(repo_root: str) -> None:
    for rel_root in TRACKED_DIRS:
        root_path = os.path.join(repo_root, rel_root)
        if not os.path.isdir(root_path) or os.path.islink(root_path):
            continue
        for dirpath, dirnames, filenames in os.walk(root_path, topdown=False):
            rel_dir = os.path.relpath(dirpath, root_path).replace(os.sep, "/")
            parts = set(rel_dir.split("/"))
            if parts & SKIP_DIR_NAMES:
                continue
            max_mtime = float(BASELINE_MTIME)
            for name in filenames + dirnames:
                if name in SKIP_DIR_NAMES:
                    continue
                child = os.path.join(dirpath, name)
                try:
                    st = os.stat(child, follow_symlinks=False)
                    if st.st_mtime > max_mtime:
                        max_mtime = st.st_mtime
                except OSError:
                    pass
            try:
                os.utime(dirpath, (max_mtime, max_mtime))
            except OSError:
                pass

    # Zed's `crates/zed/build.rs` and `crates/cli/build.rs` emit
    # `cargo:rerun-if-changed=../../.git/logs/HEAD`. Clamp the pinned Zed checkout's
    # git reflog mtimes so a fresh clone does not invalidate `zed` and `cli`.
    zed_git_dir = os.path.join(repo_root, "third_party/zed/upstream/.git")
    if os.path.isdir(zed_git_dir):
        for git_rel in ("HEAD", "logs/HEAD", "logs"):
            git_path = os.path.join(zed_git_dir, git_rel)
            if os.path.exists(git_path):
                try:
                    os.utime(git_path, (BASELINE_MTIME, BASELINE_MTIME))
                except OSError:
                    pass


def git_changed_files_since_baseline(repo_root: str) -> set[str]:
    changed: set[str] = set()
    baseline_ref = "origin/main"
    check_ref = subprocess.run(
        ["git", "-C", repo_root, "rev-parse", "--verify", baseline_ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if check_ref.returncode != 0:
        return changed

    diff_cmd = [
        "git",
        "-C",
        repo_root,
        "diff",
        "--name-only",
        baseline_ref,
        "--",
        "core/folio_engine",
        "third_party/cmark_gfm",
        "zed/folio_zed_mod",
        "zed/folio_zed_extension",
        "Cargo.toml",
        "Cargo.lock",
        "third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch",
    ]
    res = subprocess.run(diff_cmd, capture_output=True, text=True, check=False)
    if res.returncode == 0:
        for line in res.stdout.splitlines():
            if line.strip():
                changed.add(line.strip())

    untracked_cmd = [
        "git",
        "-C",
        repo_root,
        "ls-files",
        "--others",
        "--exclude-standard",
        "--",
        "core/folio_engine",
        "third_party/cmark_gfm",
        "zed/folio_zed_mod",
        "zed/folio_zed_extension",
    ]
    res_untracked = subprocess.run(
        untracked_cmd, capture_output=True, text=True, check=False
    )
    if res_untracked.returncode == 0:
        for line in res_untracked.stdout.splitlines():
            if line.strip():
                changed.add(line.strip())

    patch_rel = "third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
    zed_dir = os.path.join(repo_root, "third_party/zed/upstream")
    if patch_rel in changed and os.path.isdir(zed_dir):
        for cmd in (
            ["git", "-C", zed_dir, "diff", "--name-only"],
            ["git", "-C", zed_dir, "ls-files", "--others", "--exclude-standard"],
        ):
            zres = subprocess.run(cmd, capture_output=True, text=True, check=False)
            if zres.returncode == 0:
                for line in zres.stdout.splitlines():
                    if line.strip():
                        changed.add(f"third_party/zed/upstream/{line.strip()}")

    return changed


def restore_mtimes(repo_root: str, target_dir: str) -> None:
    if not os.path.isdir(target_dir):
        return

    manifest_path = os.path.join(target_dir, ".folio_source_hashes.json")
    now = time.time()
    clamped = 0
    touched = 0

    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                saved_hashes: dict[str, str] = json.load(f)
        except (OSError, json.JSONDecodeError):
            saved_hashes = {}

        for rel_path, full_path in iter_source_files(repo_root):
            digest = sha256_file(full_path)
            if saved_hashes.get(rel_path) == digest:
                os.utime(full_path, (BASELINE_MTIME, BASELINE_MTIME))
                clamped += 1
            else:
                os.utime(full_path, (now, now))
                touched += 1
        clamp_directories_and_git_refs(repo_root)
        print(
            f"[sync_cargo_mtimes] Restored mtimes from manifest: "
            f"{clamped} unchanged, {touched} modified."
        )
        return

    # Fallback when restoring an existing Cargo target cache created before
    # `.folio_source_hashes.json` was recorded: compare against `origin/main`.
    changed = git_changed_files_since_baseline(repo_root)
    for rel_path, full_path in iter_source_files(repo_root):
        if rel_path in changed:
            os.utime(full_path, (now, now))
            touched += 1
        else:
            os.utime(full_path, (BASELINE_MTIME, BASELINE_MTIME))
            clamped += 1
    clamp_directories_and_git_refs(repo_root)
    print(
        f"[sync_cargo_mtimes] Initialized mtimes against origin/main: "
        f"{clamped} unchanged, {touched} modified."
    )


def record_mtimes(repo_root: str, target_dir: str) -> None:
    os.makedirs(target_dir, exist_ok=True)
    manifest_path = os.path.join(target_dir, ".folio_source_hashes.json")
    hashes: dict[str, str] = {}

    for rel_path, full_path in iter_source_files(repo_root):
        hashes[rel_path] = sha256_file(full_path)
        os.utime(full_path, (BASELINE_MTIME, BASELINE_MTIME))

    clamp_directories_and_git_refs(repo_root)

    tmp_path = f"{manifest_path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(hashes, f, sort_keys=True)
    os.replace(tmp_path, manifest_path)
    print(f"[sync_cargo_mtimes] Recorded {len(hashes)} source hashes to {manifest_path}.")


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in {"restore", "record"}:
        print(
            f"Usage: {sys.argv[0]} <restore|record> <repo_root> <target_dir>",
            file=sys.stderr,
        )
        return 1

    mode = sys.argv[1]
    repo_root = os.path.abspath(sys.argv[2])
    target_dir = os.path.abspath(sys.argv[3])

    if mode == "restore":
        restore_mtimes(repo_root, target_dir)
    else:
        record_mtimes(repo_root, target_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
