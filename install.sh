#!/bin/sh
# Installs Emerald on Linux (x86-64) or macOS (Apple silicon):
#
#     curl -fsSL https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.sh | sh
#
# It downloads the latest release from GitHub, checks it against the release's
# SHA256SUMS, puts `emerald` in ~/.emerald/bin, and adds that folder to PATH in
# your shell's startup file. Running it again updates Emerald.
#
# Options, passed after `sh -s --`:
#     --version v0.5.0   install that release instead of the latest
#     --uninstall        remove Emerald and the PATH line this script added
#
# EMERALD_HOME changes the install folder (default ~/.emerald).

set -eu

repo="amortimer20/emerald-lang"
home="${EMERALD_HOME:-$HOME/.emerald}"
bin="$home/bin"
marker="# Added by the Emerald installer"
version="latest"
uninstall=false

say() { printf '%s\n' "$*"; }
usage() {
    say "Usage: install.sh [--version TAG] [--uninstall]"
    say ""
    say "  --version TAG   install that release, such as v0.5.0, instead of the latest"
    say "  --uninstall     remove Emerald and the PATH line this script added"
    say ""
    say "EMERALD_HOME changes the install folder (default ~/.emerald)."
}
fail() { printf 'emerald install: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || fail "--version needs a release tag, such as v0.5.0"
            version="$2"
            shift 2
            ;;
        --uninstall) uninstall=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option \`$1\`; the options are --version TAG and --uninstall" ;;
    esac
done

if [ "$uninstall" = true ]; then
    rm -rf "$home"
    # Every startup file this script may have added a PATH line to.
    for file in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" \
        "$HOME/.config/fish/config.fish"; do
        if [ -f "$file" ] && grep -qF "$marker" "$file"; then
            # Drop the marker line and the PATH line after it. Writing back with `cat`
            # keeps the file's permissions, and a symlinked dotfile stays a symlink.
            temp="$(mktemp)"
            awk -v marker="$marker" '$0 == marker { skip = 2 } skip > 0 { skip--; next } { print }' \
                "$file" > "$temp"
            cat "$temp" > "$file"
            rm -f "$temp"
            say "Removed Emerald from PATH in $file"
        fi
    done
    say "Emerald is uninstalled. Open a new terminal to finish."
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) asset="emerald-linux-x86_64.tar.gz" ;;
    Darwin-arm64) asset="emerald-macos-arm64.tar.gz" ;;
    Darwin-x86_64)
        # An Intel build running under Rosetta still reports arm64 hardware here.
        if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
            asset="emerald-macos-arm64.tar.gz"
        else
            fail "Emerald's Mac release is for Apple silicon (M1 or later), and this Mac has an Intel processor"
        fi
        ;;
    *) fail "there is no Emerald release for $(uname -s) on $(uname -m) yet; see https://github.com/$repo#install to build it from source" ;;
esac

if [ "$version" = latest ]; then
    base="https://github.com/$repo/releases/latest/download"
else
    base="https://github.com/$repo/releases/download/$version"
fi

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL --retry 2 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$2" "$1"; }
else
    fail "this needs curl or wget to download Emerald"
fi

if command -v sha256sum >/dev/null 2>&1; then
    digest() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    fail "this needs sha256sum or shasum to check the download"
fi

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

say "Downloading $asset ($version)..."
fetch "$base/$asset" "$temp/$asset" || fail "could not download $base/$asset; check the version and your connection"
fetch "$base/SHA256SUMS" "$temp/SHA256SUMS" || fail "could not download the release's SHA256SUMS"

# A line is "<hash>  <name>" or, for a binary-mode checksum, "<hash> *<name>".
expected="$(awk -v name="$asset" '{ file = $2; sub(/^\*/, "", file) } file == name { print $1 }' "$temp/SHA256SUMS")"
[ -n "$expected" ] || fail "the release's SHA256SUMS has no line for $asset"
[ "$(digest "$temp/$asset")" = "$expected" ] || fail "the download does not match its checksum; try again"

mkdir -p "$temp/unpacked" "$bin"
tar -xzf "$temp/$asset" -C "$temp/unpacked"
# Replace the binary by renaming, so a running `emerald` is not disturbed.
cp "$temp/unpacked/emerald" "$bin/emerald.new"
chmod 755 "$bin/emerald.new"
mv -f "$bin/emerald.new" "$bin/emerald"
for file in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ -f "$temp/unpacked/$file" ]; then cp "$temp/unpacked/$file" "$home/$file"; fi
done

installed="$("$bin/emerald" --version 2>/dev/null || true)"
[ -n "$installed" ] || fail "Emerald was downloaded to $bin, but it does not run on this machine"
say "Installed $installed to $bin/emerald"

# Put ~/.emerald/bin on PATH in the startup file of the user's shell.
case ":$PATH:" in
    *":$bin:"*) on_path=true ;;
    *) on_path=false ;;
esac

# The default folder is written as $HOME/.emerald/bin, so a synced dotfile still works
# on another machine.
if [ "$home" = "$HOME/.emerald" ]; then path_bin="\$HOME/.emerald/bin"; else path_bin="$bin"; fi
export_line="export PATH=\"$path_bin:\$PATH\""

case "$(basename "${SHELL:-sh}")" in
    zsh) profile="$HOME/.zshrc"; line="$export_line" ;;
    bash)
        # macOS Terminal starts login shells, which read .bash_profile rather than .bashrc.
        if [ "$(uname -s)" = Darwin ]; then profile="$HOME/.bash_profile"; else profile="$HOME/.bashrc"; fi
        line="$export_line"
        ;;
    fish) profile="$HOME/.config/fish/config.fish"; line="fish_add_path \"$path_bin\"" ;;
    *) profile="$HOME/.profile"; line="$export_line" ;;
esac

if [ -f "$profile" ] && grep -qF "$marker" "$profile"; then
    : # Already added by an earlier install.
else
    mkdir -p "$(dirname "$profile")"
    printf '\n%s\n%s\n' "$marker" "$line" >> "$profile"
    say "Added $bin to PATH in $profile"
fi

say ""
if [ "$on_path" = true ]; then
    say "Emerald is ready. Try: emerald --version"
else
    say "Open a new terminal, then try: emerald --version"
fi
