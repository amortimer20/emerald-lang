#!/usr/bin/env bash
# emerald fmt (§3.5): one formatting, no configuration.
#
# Not a golden case, because fmt rewrites a file rather than printing a program's
# output — so what is under test is the file afterwards.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "build failed"; exit 1
fi

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
fail=0

check() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        echo "  OK   $name"
    else
        echo "  FAIL $name"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

# Indentation, Stroustrup else, trailing space, and a brace inside an interpolation
# that must not be counted.
cat > "$sandbox/messy.em" <<'EOF'
var n = 5
if n > 3 {
print("big")
} else {
      print("small")
   }
print("#{n} and #{n}")   
EOF

dotnet "$emerald" fmt "$sandbox/messy.em" >/dev/null 2>&1
check "reformats" 'var n = 5
if n > 3 {
    print("big")
}
else {
    print("small")
}
print("#{n} and #{n}")' "$(cat "$sandbox/messy.em")"

# Running it again must change nothing.
cp "$sandbox/messy.em" "$sandbox/once.em"
dotnet "$emerald" fmt "$sandbox/messy.em" >/dev/null 2>&1
check "idempotent" "$(cat "$sandbox/once.em")" "$(cat "$sandbox/messy.em")"

# Comments survive, and a block comment's interior is left exactly as written.
cat > "$sandbox/comments.em" <<'EOF'
#[
    A . .
        . B .
]#
class Dog {
# inside
var name: String
constructor(name: String) { self.name = name }   # trailing }
}
EOF
dotnet "$emerald" fmt "$sandbox/comments.em" >/dev/null 2>&1
check "comments kept" '#[
    A . .
        . B .
]#
class Dog {
    # inside
    var name: String
    constructor(name: String) { self.name = name }   # trailing }
}' "$(cat "$sandbox/comments.em")"

# --check reports without writing, and fails so a build can gate on it.
cat > "$sandbox/gate.em" <<'EOF'
if true {
print("x")
}
EOF
before="$(cat "$sandbox/gate.em")"
dotnet "$emerald" fmt --check "$sandbox/gate.em" >/dev/null 2>&1
check "--check exit" "1" "$?"
check "--check writes nothing" "$before" "$(cat "$sandbox/gate.em")"

# A file that does not scan is refused rather than rewritten: without reliable braces,
# formatting it would turn a small mistake into a mangled file.
printf 'var s = "unterminated\nif true {\nprint(1)\n}\n' > "$sandbox/broken.em"
before="$(cat "$sandbox/broken.em")"
dotnet "$emerald" fmt "$sandbox/broken.em" >/dev/null 2>&1
check "broken file untouched" "$before" "$(cat "$sandbox/broken.em")"

echo
if [[ $fail -eq 0 ]]; then echo "fmt correct"; else echo "$fail fmt check(s) failed"; fi
exit $fail
