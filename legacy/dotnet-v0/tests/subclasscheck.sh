#!/usr/bin/env bash
# Section 5.2's first milestone: an Emerald class subclassing a C# class, with C# calling
# back in. Checked end to end -- build the fixture "library", check a real Emerald
# function through the real Scanner/Parser/Checker, graft it onto an override slot on the
# fixture's base class with tests/subclassspike, and run the result.
#
# The base class's own ShoutGreeting is what actually gets called, and it is C# Emerald
# never touched -- the only way it can answer is by calling back through the virtual
# Greet slot this emits an override for. Getting the override's method attributes wrong
# (NewSlot instead of reusing the base's slot) was tried by hand while building this and
# produced a TypeLoadException at the call site rather than at load time -- "Method
# 'Greet' in type 'EmeraldGreeter' ... does not have an implementation" -- which is the
# evidence that this test is discriminating rather than passing regardless of whether the
# wiring is right. See src/Emerald.Compiler/SubclassSpike.cs for the rest of the story.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_em="$root/tests/subclassspike/emerald/greeter.em"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

echo "building..."
for proj in "$root/tests/subclassspike/Fixture" "$root/tests/subclassspike"; do
    if ! dotnet build "$proj" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
        echo "BUILD FAILED ($proj)"
        dotnet build "$proj" --nologo -p:UseAppHost=false 2>&1 | grep -E "error" | head -10
        exit 1
    fi
done

fixture_dll="$root/tests/subclassspike/Fixture/bin/Debug/net10.0/Fixture.dll"
driver="$root/tests/subclassspike/bin/Debug/net10.0/SubclassSpike.dll"
runtime_dll="$root/src/Emerald.Runtime/bin/Debug/net10.0/Emerald.Runtime.dll"

if ! dotnet "$driver" "$fixture_em" "$fixture_dll" "$sandbox/out.dll" 2>"$sandbox/emit.err"; then
    echo "FAIL: could not emit the subclass"
    cat "$sandbox/emit.err"
    exit 1
fi

cp "$fixture_dll" "$runtime_dll" "$sandbox/"
cp "$root/tests/subclassspike/bin/Debug/net10.0/SubclassSpike.runtimeconfig.json" \
   "$sandbox/out.runtimeconfig.json"

actual="$(cd "$sandbox" && dotnet out.dll 2>&1)"
expected="HELLO FROM EMERALD!"

if [[ "$actual" == "$expected" ]]; then
    echo "C# calls back into the Emerald override correctly"
    exit 0
fi

echo "FAIL: expected '$expected', got '$actual'"
exit 1
