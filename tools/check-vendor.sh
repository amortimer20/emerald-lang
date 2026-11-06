#!/usr/bin/env bash
# Checks the recipe of docs/vendor-libraries.md: every vendor library has every item
# the recipe lists, and the list in vendor/libraries.zig matches the folders.
# Run from anywhere; it changes into the repository root.
set -u
cd "$(dirname "$0")/.."

problems=0
fail() {
    echo "check-vendor: $1" >&2
    problems=$((problems + 1))
}

# The template must stay a complete library to copy.
for item in README.md build.zig example.c example.em; do
    [ -f "vendor/_template/$item" ] || fail "vendor/_template/$item is missing"
done

# Each folder's heading list is the recipe's "Record" row.
headings=("## Upstream" "## What it exposes" "## What it leaves out, and why" "## Build" "## Testing")

listed=$(grep -o '@import("[a-z0-9_]*/build.zig")' vendor/libraries.zig | sed 's/@import("//; s|/build.zig")||')

for directory in vendor/*/; do
    name=$(basename "$directory")
    case "$name" in _*) continue ;; esac

    for item in README.md build.zig "$name.em"; do
        [ -f "vendor/$name/$item" ] || fail "vendor/$name/$item is missing"
    done
    echo "$listed" | grep -qx "$name" || fail "vendor/$name is not listed in vendor/libraries.zig"

    if [ -f "vendor/$name/README.md" ]; then
        for heading in "${headings[@]}"; do
            grep -qxF "$heading" "vendor/$name/README.md" || fail "vendor/$name/README.md has no \"$heading\" heading"
        done
    fi

    cases=$(ls conformance/vendor/"$name"/*.em 2>/dev/null | wc -l)
    [ "$cases" -gt 0 ] || fail "conformance/vendor/$name/ has no cases"
    for case in conformance/vendor/"$name"/*.em; do
        [ -f "${case%.em}.expected" ] || fail "$case has no .expected file"
    done

    # A library that ships also needs its notice, documentation, and inventory row.
    if grep -q '\.ships = true' "vendor/$name/build.zig" 2>/dev/null; then
        grep -qi "$name" THIRD_PARTY_NOTICES.md || fail "THIRD_PARTY_NOTICES.md does not mention $name"
        [ -f "docs/library/$name.md" ] || fail "docs/library/$name.md is missing"
        grep -qi "$name" docs/library/inventory.md || fail "docs/library/inventory.md does not mention $name"
        grep -q "emerald-$name" .github/workflows/release.yml || fail ".github/workflows/release.yml does not package emerald-$name"
    fi
done

for name in $listed; do
    [ -d "vendor/$name" ] || fail "vendor/libraries.zig lists $name, but vendor/$name does not exist"
done

if [ "$problems" -ne 0 ]; then
    echo "check-vendor: $problems problem(s)" >&2
    exit 1
fi
echo "check-vendor: ok"
