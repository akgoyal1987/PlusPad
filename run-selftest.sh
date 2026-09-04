#!/bin/bash
# Run the integration self test against a throwaway workspace.
#
# The test closes tabs and changes settings on purpose, so it must never touch
# the workspace someone is actually using. This builds if needed, points the app
# at a temporary directory, and cleans up afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${HERE}/build/PlusPad.app/Contents/MacOS/PlusPad"

if [[ ! -x "${APP}" ]]; then
    echo "==> building"
    "${HERE}/build.sh" >/dev/null
fi

WORKSPACE="$(mktemp -d)/PlusPad"
trap 'rm -rf "$(dirname "${WORKSPACE}")"' EXIT

PLUSPAD_WORKSPACE="${WORKSPACE}" PLUSPAD_SELFTEST=1 "${APP}" || true

if [[ -f /tmp/pluspad-selftest.log ]]; then
    cat /tmp/pluspad-selftest.log
    grep -q "FAILED" /tmp/pluspad-selftest.log && exit 1
    grep -q "REFUSED" /tmp/pluspad-selftest.log && exit 1
fi
exit 0
