#!/usr/bin/env bash
# emerald test (§3.5): *_test.em files, @test functions, convention over configuration.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "build failed"; exit 1
fi

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# A project whose tests pass, fail by returning false, and fail by throwing — and whose
# main.em must not run.
mkdir -p "$sandbox/proj"
cat > "$sandbox/proj/main.em" <<'EOF'
print("MAIN RAN")

func double(n: Int): Int { return n * 2 }
EOF
cat > "$sandbox/proj/double_test.em" <<'EOF'
@test
func doubles?(): Bool { return double(2) == 4 }

@test
func wrong_on_purpose?(): Bool { return double(2) == 5 }

@test
func throws_on_purpose() { throw "deliberate" }
EOF

out="$(dotnet "$emerald" test "$sandbox/proj" 2>&1)"
code=$?

grep -q "MAIN RAN" <<<"$out" && bad "main.em must not run during tests" || ok "main.em does not run"
grep -q "ok    DoubleTest.doubles?" <<<"$out" && ok "reports a pass" || bad "reports a pass"
grep -q "returned false" <<<"$out" && ok "reports a false return" || bad "reports a false return"
grep -q "deliberate" <<<"$out" && ok "reports a thrown message" || bad "reports a thrown message"
grep -q "3 tests, 2 failing" <<<"$out" && ok "summarizes" || bad "summarizes"
[[ $code -eq 1 ]] && ok "fails with exit 1" || bad "fails with exit 1 (got $code)"

# An enum is a type the tests must be able to see. Loading declarations for a test run
# built the classes and skipped the enums, so any test that named one failed with "No
# variable named ..." — including an enum declared in the entry file.
mkdir -p "$sandbox/enums"
cat > "$sandbox/enums/main.em" <<'EOF'
enum Color { RED, BLUE }
EOF
cat > "$sandbox/enums/side.em" <<'EOF'
enum Side { LEFT, RIGHT }
EOF
cat > "$sandbox/enums/colour_test.em" <<'EOF'
@test
func sees_an_enum_in_the_entry_file() {
    assert Color.RED.name == "RED"
}

@test
func sees_an_enum_in_another_file() {
    assert Side.values.count() == 2
}
EOF

out="$(dotnet "$emerald" test "$sandbox/enums" 2>&1)"
grep -q "2 tests, all passing" <<<"$out"     && ok "an enum is visible to a test"     || bad "an enum is visible to a test"

# All passing exits 0.
rm "$sandbox/proj/double_test.em"
cat > "$sandbox/proj/double_test.em" <<'EOF'
@test
func doubles?(): Bool { return double(2) == 4 }
EOF
dotnet "$emerald" test "$sandbox/proj" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "all passing exits 0" || bad "all passing exits 0"

# No test files, and test files without @test, are said plainly rather than counted as
# success in silence.
mkdir -p "$sandbox/bare"
printf 'print("hi")\n' > "$sandbox/bare/main.em"
grep -q "No \*_test.em files" <<<"$(dotnet "$emerald" test "$sandbox/bare" 2>&1)" \
    && ok "no test files" || bad "no test files"

# A project that does not compile reports that instead of running anything.
mkdir -p "$sandbox/broken"
printf 'print(nope)\n' > "$sandbox/broken/main.em"
printf '@test\nfunc t?(): Bool { return true }\n' > "$sandbox/broken/x_test.em"
dotnet "$emerald" test "$sandbox/broken" >/dev/null 2>&1
[[ $? -eq 65 ]] && ok "compile error exits 65" || bad "compile error exits 65"

# build, ship and add name what they need rather than shrugging.
for c in build ship add; do
    out="$(dotnet "$emerald" "$c" 2>&1)"; code=$?
    if [[ $code -eq 69 ]] && grep -q "needs" <<<"$out"; then ok "$c explains itself"
    else bad "$c explains itself"; fi
done

echo
if [[ $fail -eq 0 ]]; then echo "test command correct"; else echo "$fail check(s) failed"; fi
exit $fail
