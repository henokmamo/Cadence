#!/usr/bin/env bash
# Parse every Swift file in the repo without needing Xcode.
#
# `swiftc -parse` only checks syntax and grammar — it does not need SwiftUI,
# SwiftData or any Apple framework to exist. That makes this the cheapest possible
# smoke test on Linux or Windows (with a Swift toolchain installed): it catches the
# class of errors that would otherwise only show up on a Mac.
#
# It does NOT prove the code type-checks (for that: `swift test` for CadenceCore,
# or Xcode / the CI workflow for the app layer).
#
# Usage:  tools/ParseAllSwift.sh [path-to-swiftc]

set -uo pipefail

SWIFTC="${1:-swiftc}"
command -v "$SWIFTC" >/dev/null 2>&1 || { echo "error: '$SWIFTC' not found on PATH"; exit 2; }

cd "$(dirname "$0")/.."

fail=0
count=0
for f in $(find Cadence CadenceCore CadenceShared CadenceWidget CadenceTests CadenceCoreTests \
             -name '*.swift' 2>/dev/null | sort); do
    count=$((count + 1))
    if out=$("$SWIFTC" -parse "$f" 2>&1); then
        printf 'parse ok   %s\n' "$f"
    else
        fail=$((fail + 1))
        printf 'PARSE FAIL %s\n' "$f"
        printf '%s\n' "$out" | grep -E 'error:' | head -5 | sed 's/^/           /'
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All $count Swift files parse cleanly."
    echo "Note: syntax only. Run 'swift test' for real type-checking of CadenceCore;"
    echo "the SwiftUI/SwiftData layer is type-checked by Xcode (or .github/workflows/ci.yml)."
else
    echo "$fail of $count files failed to parse."
fi
exit "$fail"
