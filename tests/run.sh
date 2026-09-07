#!/usr/bin/env bash
# Golden tests: run each case and compare its combined output against a .expected file.
#
# Deliberately end-to-end rather than unit tests against Scanner/Parser internals — those
# would have to be rewritten every time the compiler is restructured, whereas these only
# assert what a program *does*, which is the thing that must not change silently.
#
#   ./tests/run.sh              run everything
#   ./tests/run.sh arrays       run cases matching a name
#   BLESS=1 ./tests/run.sh      rewrite .expected files from current output

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cases="$root/tests/cases"
filter="${1:-}"

pass=0; fail=0; blessed=0
failed_names=()

# A case named known_* records a defect, not a guarantee: its .expected holds what Emerald
# does today, which is wrong. Blessing one keeps the suite green, so without this list a
# recorded hole is indistinguishable from a passing test, and "matches today's output"
# quietly becomes the standard. They are reported by name on every run instead, and the
# fix for one is a rewritten .expected, not a deleted file.
known_names=()

echo "building..."
# UseAppHost=false skips the native launcher, which cannot be made executable on a Windows
# drive mounted under WSL. Invoking the DLL directly works on both platforms, and skips
# `dotnet run`'s per-invocation project check.
if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "BUILD FAILED"
    dotnet build "$root/src/Emerald" --nologo -p:UseAppHost=false 2>&1 \
        | grep -E "error" | head -10
    exit 1
fi

emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"

# Goldens may have been written on either platform; compare content, not line endings.
strip_cr() { tr -d '\r'; }

# A project is a directory, so a single-file case has to run alone — otherwise every case
# in tests/cases would be loaded as part of every other one. Multi-file cases are written
# as a directory containing main.em.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

for case_path in "$cases"/*.em "$cases"/*/; do
    [[ -e "$case_path" ]] || continue

    if [[ -d "$case_path" ]]; then
        name="$(basename "$case_path")"
        entry="$case_path/main.em"
        [[ -f "$entry" ]] || { echo "SKIP     $name (no main.em)"; continue; }
        prefix="${case_path%/}"
    else
        name="$(basename "$case_path" .em)"
        entry="$case_path"
        prefix="${case_path%.em}"
    fi

    if [[ -n "$filter" && "$name" != *"$filter"* ]]; then continue; fi

    expected_file="$prefix.expected"
    stdin_file="$prefix.stdin"
    input="/dev/null"
    [[ -f "$stdin_file" ]] && input="$stdin_file"

    run_dir="$sandbox/$name"
    rm -rf "$run_dir"; mkdir -p "$run_dir"
    if [[ -d "$case_path" ]]; then cp -r "$case_path"/*.em "$run_dir/"
    else cp "$entry" "$run_dir/"; fi

    actual="$(dotnet "$emerald" run "$run_dir/$(basename "$entry")" < "$input" 2>&1 | strip_cr)"

    if [[ "${BLESS:-}" == "1" ]]; then
        printf '%s\n' "$actual" > "$expected_file"
        blessed=$((blessed + 1))
        continue
    fi

    if [[ ! -f "$expected_file" ]]; then
        echo "MISSING  $name  (no .expected — run with BLESS=1 to create)"
        fail=$((fail + 1)); failed_names+=("$name")
        continue
    fi

    expected="$(strip_cr < "$expected_file")"

    if [[ "$actual" == "$expected" ]]; then
        pass=$((pass + 1))
        [[ "$name" == known_* ]] && known_names+=("$name")
    else
        fail=$((fail + 1)); failed_names+=("$name")
        echo "FAIL     $name"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
            | sed 's/^/         /' | head -20
    fi
done

echo
if [[ "${BLESS:-}" == "1" ]]; then
    echo "blessed $blessed case(s)"
    exit 0
fi

echo "$pass passed, $fail failed"
if (( ${#known_names[@]} > 0 )); then
    echo "  ${#known_names[@]} recorded hole(s), passing against known-wrong output:"
    printf '    %s
' "${known_names[@]}"
fi
if (( fail > 0 )); then
    printf '  failed: %s\n' "${failed_names[*]}"
    exit 1
fi
