#!/usr/bin/env bash
# Usage: app_identity_test.sh <dev|release> <bundle ID> <bundle name> <LSHandlerRank> <FolioApp rlocation paths...>
# Checks the identity keys in the built Info.plist. RELEASE_BUNDLE_ID comes from the test env.
set -euo pipefail

channel="$1"
expected_id="$2"
expected_name="$3"
expected_rank="$4"
shift 4
app=""
for path in "$@"; do
    if [[ "${path}" == *.app ]]; then
        app="${TEST_SRCDIR:-${RUNFILES_DIR:-}}/${path}"
    fi
done
plist="${app}/Contents/Info.plist"
failures=0

value() { /usr/libexec/PlistBuddy -c "Print :$1" "${plist}" 2>/dev/null || true; }

expect() {
    local key="$1" expected="$2" actual
    actual="$(value "${key}")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "FAIL: ${key} is '${actual}', expected '${expected}'" >&2
        failures=$((failures + 1))
    fi
}

if [[ ! -f "${plist}" ]]; then
    echo "FAIL: no Info.plist at ${plist}" >&2
    exit 1
fi

expect CFBundleIdentifier "${expected_id}"
expect CFBundleName "${expected_name}"
expect CFBundleDisplayName "${expected_name}"
expect FolioBuildChannel "${channel}"

if [[ "${channel}" == "dev" && "$(value CFBundleIdentifier)" == "${RELEASE_BUNDLE_ID}" ]]; then
    echo "FAIL: the dev build uses the release bundle ID ${RELEASE_BUNDLE_ID}" >&2
    failures=$((failures + 1))
fi

doc_types="$(/usr/bin/plutil -extract CFBundleDocumentTypes raw -o - "${plist}" 2>/dev/null || echo 0)"
if (( doc_types == 0 )); then
    echo "FAIL: no CFBundleDocumentTypes" >&2
    failures=$((failures + 1))
fi
for ((i = 0; i < doc_types; i++)); do
    expect "CFBundleDocumentTypes:${i}:LSHandlerRank" "${expected_rank}"
done

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: ${channel} build is ${expected_id} (${expected_name}), LSHandlerRank ${expected_rank}"
