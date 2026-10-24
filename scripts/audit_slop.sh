#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MAX_LINES="${MAX_LINES:-350}"
WARN_LINES="${WARN_LINES:-250}"
FAILED=0

echo "=== [1/6] Checking Rust src/ & tst/ files for line count (warn > ${WARN_LINES}, max ${MAX_LINES}) ==="
while IFS= read -r -d '' file; do
    lines="$(wc -l < "${file}" | tr -d ' ')"
    rel="${file#${REPO_ROOT}/}"
    if (( lines > MAX_LINES )); then
        echo "❌ FAIL: ${rel} has ${lines} lines (exceeds max ${MAX_LINES} lines). Split into submodules!"
        FAILED=1
    elif (( lines > WARN_LINES )); then
        echo "⚠️  WARN: ${rel} has ${lines} lines (target <= ${WARN_LINES} lines)."
    fi
done < <(find core zed -name "*.rs" -not -path "*/target/*" -type f -print0)

echo "=== [2/6] Checking Swift Sources/ & Tests/ files for line count (warn > ${WARN_LINES}, max ${MAX_LINES}) ==="
while IFS= read -r -d '' file; do
    lines="$(wc -l < "${file}" | tr -d ' ')"
    rel="${file#${REPO_ROOT}/}"
    if (( lines > MAX_LINES )); then
        echo "❌ FAIL: ${rel} has ${lines} lines (exceeds max ${MAX_LINES} lines). Split into focused files/extensions!"
        FAILED=1
    elif (( lines > WARN_LINES )); then
        echo "⚠️  WARN: ${rel} has ${lines} lines (target <= ${WARN_LINES} lines)."
    fi
done < <(find Sources Tests -name "*.swift" -type f -print0)

if [[ -f "${REPO_ROOT}/Tests/FolioTests/FolioTests.swift" ]]; then
    echo "❌ FAIL: Tests/FolioTests/FolioTests.swift exists! Keep tests organized in domain-specific *Tests.swift files."
    FAILED=1
fi

echo "=== [3/6] Checking that no inline tests exist inside Rust src/ (must be in tst/) ==="
while IFS= read -r -d '' file; do
    rel="${file#${REPO_ROOT}/}"
    if grep -nE '#\[(cfg\(test\)|test)\]' "${file}" >/dev/null 2>&1; then
        echo "❌ FAIL: ${rel} contains inline #[cfg(test)] or #[test]. Move all tests into tst/!"
        grep -nE '#\[(cfg\(test\)|test)\]' "${file}"
        FAILED=1
    fi
done < <(find core zed -path "*/src/*.rs" -not -path "*/target/*" -type f -print0)

echo "=== [4/6] Checking that every workspace crate has a tst/ directory and all src/ & tst/ files are registered in Cargo.toml & BUILD.bazel ==="
for crate_dir in core/folio_engine zed/folio_zed_extension; do
    if [[ ! -d "${crate_dir}/tst" ]]; then
        echo "❌ FAIL: ${crate_dir}/tst directory is missing!"
        FAILED=1
        continue
    fi
    cargo_toml="${crate_dir}/Cargo.toml"
    build_bazel="${crate_dir}/BUILD.bazel"
    while IFS= read -r -d '' tst_file; do
        rel_tst="${tst_file#${crate_dir}/}"
        if ! grep -Fq "\"${rel_tst}\"" "${cargo_toml}"; then
            echo "❌ FAIL: ${crate_dir}/${rel_tst} is not registered in ${cargo_toml} [[test]]!"
            FAILED=1
        fi
        if ! grep -Fq "\"${rel_tst}\"" "${build_bazel}"; then
            echo "❌ FAIL: ${crate_dir}/${rel_tst} is not registered in ${build_bazel} rust_test!"
            FAILED=1
        fi
    done < <(find "${crate_dir}/tst" -name "*.rs" -type f -print0)

    while IFS= read -r -d '' src_file; do
        rel_src="${src_file#${crate_dir}/}"
        if ! grep -Fq "\"${rel_src}\"" "${build_bazel}"; then
            echo "❌ FAIL: ${crate_dir}/${rel_src} is not listed in ${build_bazel} srcs!"
            FAILED=1
        fi
    done < <(find "${crate_dir}/src" -name "*.rs" -type f -print0)
done

echo "=== [5/6] Validating shared declarative behavior specs (tst/specs/editor_behaviors.json) ==="
if [[ ! -f "tst/specs/editor_behaviors.json" ]]; then
    echo "❌ FAIL: tst/specs/editor_behaviors.json is missing!"
    FAILED=1
else
    python3 -c '
import json, pathlib, sys
data = json.loads(pathlib.Path("tst/specs/editor_behaviors.json").read_text())
assert len(data.get("cursor_edit_cases", [])) >= 15, "Expected >= 15 cursor_edit_cases"
assert len(data.get("fold_reveal_cases", [])) >= 2, "Expected >= 2 fold_reveal_cases"
' || {
        echo "❌ FAIL: tst/specs/editor_behaviors.json failed schema validation!"
        FAILED=1
    }
fi

if (( FAILED != 0 )); then
    echo ""
    echo "Audit failed structural checks. Fix the issues above before proceeding."
    exit 1
fi

echo "=== [6/6] Running cargo clippy (workspace + WASI extension crate) & cargo test ==="
cargo clippy --workspace --all-targets -- -D warnings
cargo clippy --manifest-path zed/folio_zed_extension/wasm/Cargo.toml --all-targets -- -D warnings -A clippy::too_many_arguments
if rustup target list --installed 2>/dev/null | grep -q '^wasm32-wasip2$'; then
    cargo clippy --manifest-path zed/folio_zed_extension/wasm/Cargo.toml --target wasm32-wasip2 -- -D warnings -A clippy::too_many_arguments
fi
cargo test --workspace

echo "✅ All anti-slop hygiene checks, clippy lints, and workspace tests passed!"
