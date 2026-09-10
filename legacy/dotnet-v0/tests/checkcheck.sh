#!/usr/bin/env bash
# Checks `emerald check`: it must find problems *without running the program*, and its
# --json output is the contract the editor extension depends on.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

printf 'print("SHOULD NOT RUN")\nvar x = 1\nx\n' > "$dir/main.em"

echo "=== check does not execute the program ==="
out="$(dotnet "$emerald" check "$dir/main.em" 2>&1)"
grep -q "SHOULD NOT RUN" <<< "$out" && bad "it ran the program" || ok "did not run it"
grep -q "does nothing" <<< "$out" && ok "found the problem" || bad "missed the problem"

echo
echo "=== --json carries what the editor needs ==="
json="$(dotnet "$emerald" check --json "$dir/main.em")"
grep -q '"diagnostics"' <<< "$json" && ok "has diagnostics" || bad "no diagnostics key"
grep -q '"line":3' <<< "$json"      && ok "line number"     || bad "wrong or missing line"
grep -q '"message":'  <<< "$json"   && ok "message"         || bad "no message"
grep -q '"hint":"'    <<< "$json"   && ok "hint"            || bad "no hint"

echo
echo "=== a clean file reports none ==="
printf 'print("fine")\n' > "$dir/main.em"
dotnet "$emerald" check "$dir/main.em" | grep -q "no problems" && ok "human output" || bad "human output"
[[ "$(dotnet "$emerald" check --json "$dir/main.em")" == '{"diagnostics":[]}' ]] \
    && ok "empty json" || bad "empty json"

echo
(( fail == 0 )) && echo "check command correct" || { echo "check command failed"; exit 1; }
