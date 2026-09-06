#!/usr/bin/env bash
# emerald explain (§3.5): bare invocation explains the last error, and every explanation
# shows broken code beside fixed code rather than prose about the concept.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "build failed"; exit 1
fi

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
fail=0

ok()   { echo "  OK   $1"; }
bad()  { echo "  FAIL $1"; fail=$((fail + 1)); }
has()  { if grep -q "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi }

# Every explanation must show both halves — that is the form §3.5 settles.
for topic in $(dotnet "$emerald" explain --list | awk '/^  [a-z][a-z-]+ {2,}/ { print $1 }'); do
    body="$(dotnet "$emerald" explain "$topic" 2>&1)"
    if grep -q "This does not work:" <<<"$body" && grep -q "This does:" <<<"$body"; then
        ok "explains $topic"
    else
        bad "explains $topic"
    fi
done

# An error records its topic, so the next bare invocation explains it with no argument
# to transcribe.
mkdir -p "$sandbox/prog"
printf 'var name: String? = nothing\nprint(name.length)\n' > "$sandbox/prog/main.em"
run_out="$(dotnet "$emerald" run "$sandbox/prog/main.em" 2>&1)"
has "error offers explain" "emerald explain" "$run_out"
has "bare explain follows it" "might be nothing" "$(dotnet "$emerald" explain 2>&1)"

# A different error replaces it.
printf 'struct P {\n    var x: Int\n}\nvar p = P(1)\np.x = 2\n' > "$sandbox/prog/main.em"
dotnet "$emerald" run "$sandbox/prog/main.em" >/dev/null 2>&1
has "last error wins" "Changing a struct" "$(dotnet "$emerald" explain 2>&1)"

# An error with no explanation written for it must clear the last one. Explaining a
# mistake the reader is not looking at is worse than explaining nothing, because they
# have no way to tell it is the wrong answer.
printf 'var n: Int = 1\nn = \"hello\"\n' > "$sandbox/prog/main.em"
dotnet "$emerald" run "$sandbox/prog/main.em" >/dev/null 2>&1
after="$(dotnet "$emerald" explain 2>&1)"
has "topicless error forgets the last one" "does not have an explanation written" "$after"
if grep -q "Changing a struct" <<<"$after"; then
    bad "topicless error leaves a stale explanation"
else
    ok "topicless error leaves no stale explanation"
fi

# A crash is the last thing the compiler said too, and it carries no topic either.
printf 'var xs = [1, 2]\nprint(xs[9])\n' > "$sandbox/prog/main.em"
dotnet "$emerald" run "$sandbox/prog/main.em" >/dev/null 2>&1
has "runtime failure forgets too" "does not have an explanation written" \
    "$(dotnet "$emerald" explain 2>&1)"

# An unknown name says so rather than inventing an answer.
dotnet "$emerald" explain frobnicate >/dev/null 2>&1
[[ $? -eq 66 ]] && ok "unknown topic exits 66" || bad "unknown topic exits 66"

echo
if [[ $fail -eq 0 ]]; then echo "explain correct"; else echo "$fail explain check(s) failed"; fi
exit $fail
