#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_version="$(cat "$repo_root/toolchain/zig-version.txt")"

if command -v mise >/dev/null 2>&1; then
    zig_bin="$(mise which zig 2>/dev/null)"
else
    zig_bin="$(command -v zig)"
fi

actual_version="$("$zig_bin" version)"

if [[ "$actual_version" != "$expected_version" ]]; then
    echo "Zig version mismatch." >&2
    echo "Expected: $expected_version" >&2
    echo "Actual:   $actual_version" >&2
    exit 1
fi

probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT

"$zig_bin" build-exe "$repo_root/toolchain/probes/smoke.zig" \
    -femit-bin="$probe_dir/smoke" \
    --cache-dir "$probe_dir/local-cache" \
    --global-cache-dir "$probe_dir/global-cache"

output="$("$probe_dir/smoke" 2>&1)"

if [[ "$output" != "Zig toolchain ready." ]]; then
    echo "Zig smoke probe returned unexpected output: $output" >&2
    exit 1
fi

echo "$actual_version"
echo "$output"
