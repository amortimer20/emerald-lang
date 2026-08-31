#!/usr/bin/env bash
# Checks that `exit` produces the right process exit code. The golden suite compares
# output, so it cannot see this — but the exit code is part of the CLI's contract with
# whatever runs an Emerald program.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

check() {
    local label="$1" source="$2" want="$3"
    printf '%s\n' "$source" > "$dir/main.em"
    dotnet "$emerald" run "$dir/main.em" >/dev/null 2>&1
    local got=$?
    printf '%-28s want %s, got %s  ' "$label" "$want" "$got"
    if [[ "$got" == "$want" ]]; then echo "OK"; else echo "FAILED"; return 1; fi
}

fail=0
check "exit()"          'print("ok")
exit()'                 0 || fail=1
check "exit(3)"         'exit(3)'                     3 || fail=1
check "falls off the end" 'print("done")'             0 || fail=1
# Needs an error the checker genuinely cannot see. `nothing.abs` will not do — that is
# caught statically, which is the type system working.
check "runtime error"   'var ns = [1, 2]
var i = ns.count + 5
print(ns[i])'                                         70 || fail=1
check "compile error"   'print(undefined_name)'       65 || fail=1

echo
(( fail == 0 )) && echo "exit codes correct" || { echo "exit code check failed"; exit 1; }
