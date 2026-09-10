#!/usr/bin/env bash
# Checks docs/tour.html against the compiler.
#
# The tour's claim is that every program on it was run before the page was written. That
# was true once and nothing kept it true — a language change reaches the .em corpus
# through the golden tests and reached the tour only through somebody remembering. It did
# not get remembered: requiring parentheses on every call (§3.1) left nine stale snippets
# on the page, four of which no earlier grep had found.
#
#   ./tests/tourcheck.sh           check
#   ./tests/tourcheck.sh --list    name every section and what it ran

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "building..."
if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "BUILD FAILED"
    exit 1
fi

python3 "$root/tools/tourcheck.py" "$@"
