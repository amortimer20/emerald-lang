#!/usr/bin/env bash
# Smoke-runs every example project. Each examples/<name>/ is its own project, because a
# directory *is* a project (§3.3) — a folder of unrelated .em files would load as one.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

fail=0
for dir in "$root"/examples/*/; do
    name="$(basename "$dir")"
    entry="$dir/main.em"
    [[ -f "$entry" ]] || entry="$(find "$dir" -maxdepth 1 -name '*.em' | head -1)"
    [[ -f "$entry" ]] || { printf '%-22s SKIP (no .em)\n' "$name"; continue; }

    # Interactive examples need enough input to finish. A guessing game that reads
    # until it wins needs a range plus every guess in it.
    case "$name" in
        mad_lib)        input=$'A\nb\nc\nd\n1\n' ;;
        hello)          input=$'Ada\n' ;;
        *guessing*)     input=$'1\n100\n'"$(seq 1 100)" ;;
        *)              input="" ;;
    esac

    printf '%-22s' "$name"
    if printf '%s\n' "$input" | dotnet "$emerald" run "$entry" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        fail=$((fail + 1))
    fi
done

echo
(( fail == 0 )) && echo "all examples ran" || { echo "$fail example(s) failed"; exit 1; }
