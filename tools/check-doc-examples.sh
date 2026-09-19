#!/usr/bin/env bash
# docs/README.md's work-order step 4: check that every example or conformance
# file the documentation links to still exists, and that every linked
# examples/ file (the ones with no .expected pinning their output, unlike
# conformance/, which zig build test already verifies exactly) still runs to
# completion. This does not duplicate the conformance suite; it only guards
# against a documentation page quietly outliving the file it points at.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

emerald_bin="zig-out/bin/emerald"
if [[ ! -x "$emerald_bin" ]]; then
    echo "Build the compiler first: zig build" >&2
    exit 1
fi

mapfile -t links < <(
    grep -rohE '\]\(\.\./\.\./[A-Za-z0-9_./-]+\.em\)' docs/language docs/library \
        | sed -E 's/^\]\(\.\.\/\.\.\///; s/\)$//' \
        | sort -u
)

# A project case (conformance/README.md) is a directory holding main.em, so a
# page links the bare directory rather than one file inside it. These follow
# examples/<name> or conformance/{run,diagnostics,runtime-errors}/<name> with
# no extension; anything else with no `.em` is a cross-reference to another
# doc page, not a code link, and is out of scope here.
mapfile -t project_links < <(
    grep -rohE '\]\(\.\./\.\./(examples|conformance/(run|diagnostics|runtime-errors))/[A-Za-z0-9_-]+\)' docs/language docs/library \
        | sed -E 's/^\]\(\.\.\/\.\.\///; s/\)$//' \
        | sort -u
)

if [[ "${#links[@]}" -eq 0 && "${#project_links[@]}" -eq 0 ]]; then
    echo "No .em or project-directory links found under docs/language or docs/library; the link pattern may need updating." >&2
    exit 1
fi

missing=0
broken=0
checked_examples=0

for link in "${links[@]}"; do
    if [[ ! -f "$link" ]]; then
        echo "MISSING: $link (linked from docs, but no longer exists)" >&2
        missing=$((missing + 1))
        continue
    fi

    if [[ "$link" == examples/*.em ]]; then
        checked_examples=$((checked_examples + 1))
        # A couple of blank lines satisfy any example that calls input()
        # without raising InputError; one that never reads stdin ignores them.
        if ! output=$(printf '\n\n\n\n\n' | "$emerald_bin" run "$link" 2>&1); then
            echo "BROKEN: $link failed to run:" >&2
            echo "$output" | sed 's/^/    /' >&2
            broken=$((broken + 1))
        fi
    fi
done

for link in "${project_links[@]}"; do
    if [[ ! -f "$link/main.em" ]]; then
        echo "MISSING: $link/main.em (project case linked from docs, but no longer exists)" >&2
        missing=$((missing + 1))
        continue
    fi

    if [[ "$link" == examples/* ]]; then
        checked_examples=$((checked_examples + 1))
        if ! output=$(printf '\n\n\n\n\n' | "$emerald_bin" run "$link/main.em" 2>&1); then
            echo "BROKEN: $link/main.em failed to run:" >&2
            echo "$output" | sed 's/^/    /' >&2
            broken=$((broken + 1))
        fi
    fi
done

link_count=$((${#links[@]} + ${#project_links[@]}))

echo "Checked $link_count linked file(s): $checked_examples example(s) executed, $((link_count - checked_examples)) conformance file(s) confirmed present (behavior already verified by \`zig build test\`)."

if [[ "$missing" -gt 0 || "$broken" -gt 0 ]]; then
    echo "$missing missing, $broken broken." >&2
    exit 1
fi

echo "All documentation examples are present and executable."
