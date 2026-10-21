#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <bazel_target>" >&2
    exit 1
fi

TARGET="$1"
REPO_ROOT="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_ROOT}"

LABELS="$(bazel query --noshow_progress --ui_event_filters=-info,-stderr "filter('^//', kind('source file', deps(${TARGET})))" 2>/dev/null)"

python3 - "${REPO_ROOT}" "${LABELS}" <<'PY'
import hashlib
import os
import sys

repo_root = sys.argv[1]
raw_labels = sys.argv[2].splitlines()

rel_paths = set()
for label in raw_labels:
    label = label.strip()
    if not label.startswith("//"):
        continue
    body = label[2:]
    if ":" in body:
        pkg, name = body.split(":", 1)
        rel = f"{pkg}/{name}" if pkg else name
        build_file = f"{pkg}/BUILD.bazel" if pkg else "BUILD.bazel"
        if os.path.isfile(os.path.join(repo_root, build_file)):
            rel_paths.add(build_file)
    else:
        rel = body
    if os.path.isfile(os.path.join(repo_root, rel)):
        rel_paths.add(rel)

for global_cfg in (".bazelrc", "MODULE.bazel", "MODULE.bazel.lock"):
    if os.path.isfile(os.path.join(repo_root, global_cfg)):
        rel_paths.add(global_cfg)

digest = hashlib.sha256()
for rel in sorted(rel_paths):
    full_path = os.path.join(repo_root, rel)
    file_hash = hashlib.sha256()
    with open(full_path, "rb") as f:
        while chunk := f.read(65536):
            file_hash.update(chunk)
    digest.update(f"{rel}:{file_hash.hexdigest()}\n".encode("utf-8"))

print(digest.hexdigest())
PY
