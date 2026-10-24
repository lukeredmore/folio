#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MAX_LINES="${MAX_LINES:-350}"
WARN_LINES="${WARN_LINES:-250}"
FAILED=0

echo "=== [1/5] Checking Rust src/ & tst/ files for line count (warn > ${WARN_LINES}, max ${MAX_LINES}) ==="
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

echo "=== [2/5] Checking Swift Sources/ & Tests/ files for line count (warn > ${WARN_LINES}, max ${MAX_LINES}) ==="
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

echo "=== [3/5] Checking that no inline tests exist inside Rust src/ (must be in tst/) ==="
while IFS= read -r -d '' file; do
    rel="${file#${REPO_ROOT}/}"
    if grep -nE '#\[(cfg\(test\)|test)\]' "${file}" >/dev/null 2>&1; then
        echo "❌ FAIL: ${rel} contains inline #[cfg(test)] or #[test]. Move all tests into tst/!"
        grep -nE '#\[(cfg\(test\)|test)\]' "${file}"
        FAILED=1
    fi
done < <(find core zed -path "*/src/*.rs" -not -path "*/target/*" -type f -print0)

echo "=== [4/5] Checking that every workspace crate has a tst/ directory ==="
for crate_dir in core/folio_engine zed/folio_zed_extension; do
    if [[ ! -d "${crate_dir}/tst" ]]; then
        echo "❌ FAIL: ${crate_dir}/tst directory is missing!"
        FAILED=1
    fi
done

if (( FAILED != 0 )); then
    echo ""
    echo "Audit failed structural checks. Fix the issues above before proceeding."
    exit 1
fi

echo "=== [5/5] Running cargo clippy & cargo test ==="
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

echo "✅ All anti-slop hygiene checks, clippy lints, and workspace tests passed!"
