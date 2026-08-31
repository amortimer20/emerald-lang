#!/usr/bin/env bash
# Checks `emerald new` — that it creates a runnable project, and that its refusals are
# clear. Not a golden test: it writes directories, so it runs in a sandbox of its own.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cd "$dir"

echo "=== creates a project that runs ==="
dotnet "$emerald" new my_first_game
echo "--- main.em ---"
cat my_first_game/main.em
echo "--- running it ---"
printf 'Ada\n' | dotnet "$emerald" run my_first_game/main.em

echo
echo "=== refuses an existing directory ==="
dotnet "$emerald" new my_first_game 2>&1; echo "  (exit $?)"

echo
echo "=== refuses a name that will not work ==="
dotnet "$emerald" new 2fast 2>&1; echo "  (exit $?)"

echo
echo "=== asks for a name ==="
dotnet "$emerald" new 2>&1; echo "  (exit $?)"
