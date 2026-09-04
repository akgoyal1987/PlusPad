#!/bin/bash
# Compile and run the core logic tests. UI files are excluded: these cover the
# pieces that can be checked without a window server, which is also where a
# defect is hardest to notice by using the app.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(mktemp -d)/pluspad-tests"

swiftc -O \
    "${HERE}/Sources/PlusPad/Encoding.swift" \
    "${HERE}/Sources/PlusPad/Languages.swift" \
    "${HERE}/Sources/PlusPad/Theme.swift" \
    "${HERE}/Sources/PlusPad/Highlighter.swift" \
    "${HERE}/Sources/PlusPad/Scanners.swift" \
    "${HERE}/Sources/PlusPad/TextOps.swift" \
    "${HERE}/Sources/PlusPad/FindEngine.swift" \
    "${HERE}/tests/main.swift" \
    -o "${BIN}"

"${BIN}"
