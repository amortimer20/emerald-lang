#!/usr/bin/env bash
# The shipped runtime library, exercised by a plain C# program with no compiler involved.
#
# The values it prints are already covered by the golden cases. What this checks is the
# boundary: tests/runtimecaller references Emerald.Runtime and nothing else, so a rule the
# backend will need cannot quietly drift back into the compiler without this failing to
# build. A reference list enforces that; discipline does not.
#
# It is also a rehearsal for emitted code. Every call in Program.cs is a static method on
# a plain type taking plain values -- no interpreter, no boxed argument list, no AST.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
caller="$root/tests/runtimecaller"

if ! dotnet build "$caller" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "BUILD FAILED — the runtime library no longer stands on its own"
    dotnet build "$caller" --nologo -p:UseAppHost=false 2>&1 | grep -E "error" | head -10
    exit 1
fi

actual="$(dotnet "$caller/bin/Debug/net10.0/RuntimeCaller.dll" | tr -d '\r')"
expected="$(tr -d '\r' < "$caller/expected.txt")"

if [[ "$actual" == "$expected" ]]; then
    echo "runtime library correct"
    exit 0
fi

echo "FAIL: the runtime library answered differently to a plain C# caller"
diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
exit 1
