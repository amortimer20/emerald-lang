#!/usr/bin/env bash
# emerald repl (§3.5): deferred but preserved — a single statement parses standalone and
# the environment is an ordinary object, which is what makes this cheap.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "build failed"; exit 1
fi

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# Runs a session and checks the whole transcript for a string.
session() { dotnet "$emerald" repl 2>&1; }
has() { if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi }
lacks() { if grep -qF "$2" <<<"$3"; then bad "$1 (found: $2)"; else ok "$1"; fi }

out="$(printf '1 + 1\n:quit\n' | session)"
has "an expression prints" "2" "$out"

out="$(printf 'var x = 5\nx * 2\n:quit\n' | session)"
has "state persists between entries" "10" "$out"

out="$(printf 'func double(n: Int): Int {\n    return n * 2\n}\ndouble(21)\n:quit\n' | session)"
has "multi-line entries" "42" "$out"

out="$(printf 'class Dog {\n    var name: String\n    constructor(name: String) { self.name = name }\n    func speak(): String { return "#{self.name} woofs" }\n}\nDog("rex").speak()\n:quit\n' | session)"
has "a class defined and used" "rex woofs" "$out"

# A name entered again replaces the earlier one, rather than overloading it.
out="$(printf 'func f(n: Int): Int { return n }\nfunc f(n: Int): Int { return n * 100 }\nf(2)\n:quit\n' | session)"
has "redefinition replaces" "200" "$out"
lacks "redefinition is not an overload clash" "already has an overload" "$out"

# An error does not end the session, and does not repeat at every later prompt.
out="$(printf 'undefined_thing\n"still here"\n:quit\n' | session)"
has "an error is reported" "No variable named undefined_thing" "$out"
has "the session survives it" "still here" "$out"

out="$(printf 'var badName = 1\nbadName\nbadName\n:quit\n' | session)"
if [[ $(grep -cF "reads as a type" <<<"$out") -eq 1 ]]; then
    ok "a warning reports once, not at every later prompt"
else
    bad "a warning reports once, not at every later prompt"
fi

# A runtime failure is caught and the prompt returns.
out="$(printf '1 / 0\n"after"\n:quit\n' | session)"
has "a runtime failure is caught" "Cannot divide by zero" "$out"
has "and the prompt returns" "after" "$out"

out="$(printf 'var x = 1\nfunc f(): Int { return 1 }\n:what\n:quit\n' | session)"
has ":what lists what was defined" "x, f" "$out"

# Ctrl+D, which is end of input here, leaves cleanly.
printf '1 + 1\n' | session >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "end of input exits 0" || bad "end of input exits 0"

echo
if [[ $fail -eq 0 ]]; then echo "repl correct"; else echo "$fail repl check(s) failed"; fi
exit $fail
