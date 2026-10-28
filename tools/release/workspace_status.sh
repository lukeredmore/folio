#!/usr/bin/env bash
# Prints the stamp keys that --config=release embeds in Folio.app and the Zed extension.
set -euo pipefail

echo "STABLE_FOLIO_BUILD_NUMBER ${FOLIO_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
echo "STABLE_FOLIO_COMMIT_SHA ${FOLIO_COMMIT_SHA:-$(git rev-parse --short HEAD)}"
if [[ -n "${FOLIO_VERSION:-}" ]]; then
  echo "STABLE_FOLIO_VERSION ${FOLIO_VERSION}"
fi
