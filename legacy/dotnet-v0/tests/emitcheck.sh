#!/usr/bin/env bash
# The first differential test: the interpreter and a freshly emitted assembly, run on the
# same source, checked against each other rather than against a fixed golden file. This is
# the "two implementations, one the oracle" idea from docs/cil-mapping.html's own notes,
# made real for the first time.
#
# tests/emitspike is deliberately not part of the emerald CLI -- it exists to answer three
# questions before any real backend work begins: does Mono.Cecil produce something the
# current .NET runtime will load; does an emitted call into Emerald.Runtime behave
# identically to the interpreter calling the same code; and does anything on this machine
# (Smart App Control chief among the suspects) object to a freshly emitted assembly being
# built and executed. See src/Emerald.Compiler/Emitter.cs for what it does and does not
# support -- one shape of program, refused loudly outside that shape.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$root/tests/emitspike/fixture/main.em"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

echo "building..."
if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "BUILD FAILED (interpreter)"
    exit 1
fi
if ! dotnet build "$root/tests/emitspike" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "BUILD FAILED (emitspike)"
    dotnet build "$root/tests/emitspike" --nologo -p:UseAppHost=false 2>&1 \
        | grep -E "error" | head -10
    exit 1
fi

emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"
emitspike="$root/tests/emitspike/bin/Debug/net10.0/EmitSpike.dll"
runtime_dll="$root/src/Emerald.Runtime/bin/Debug/net10.0/Emerald.Runtime.dll"

interpreted="$(dotnet "$emerald" run "$fixture" 2>&1)"

if ! dotnet "$emitspike" "$fixture" "$sandbox/main.dll" 2>"$sandbox/emit.err"; then
    echo "FAIL: the emitter could not compile the fixture"
    cat "$sandbox/emit.err"
    exit 1
fi

# What a real build would also produce beside the entry assembly: the runtime library the
# emitted call sites reference, and a runtimeconfig.json naming the framework to load. The
# emitspike driver's own config already names the right one, since it targets the same TFM.
cp "$runtime_dll" "$sandbox/"
cp "$root/tests/emitspike/bin/Debug/net10.0/EmitSpike.runtimeconfig.json" \
   "$sandbox/main.runtimeconfig.json"

compiled="$(cd "$sandbox" && dotnet main.dll 2>&1)"

if [[ "$interpreted" == "$compiled" ]]; then
    echo "emitted assembly agrees with the interpreter"
    exit 0
fi

echo "FAIL: emitted assembly disagreed with the interpreter"
diff <(printf '%s\n' "$interpreted") <(printf '%s\n' "$compiled") | sed 's/^/  /'
exit 1
