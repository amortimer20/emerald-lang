#!/usr/bin/env bash
# Installs the `emerald` command for the current user.
#
#   bash tools/install-cli.sh
#
# Puts a small launcher in ~/.local/bin that delegates to tools/emerald in this checkout,
# so editing the repo copy takes effect immediately. Adds ~/.local/bin to PATH via
# ~/.bashrc only if it is not already there.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$HOME/.local/bin"
mkdir -p "$bin"

cat > "$bin/emerald" <<LAUNCHER
#!/usr/bin/env bash
# Launcher for the emerald command — delegates to the checkout so repo edits take effect.
export EMERALD_ROOT="\${EMERALD_ROOT:-$root}"
exec "\$EMERALD_ROOT/tools/emerald" "\$@"
LAUNCHER

chmod +x "$bin/emerald"
echo "installed $bin/emerald  ->  $root"

marker="# added by emerald-lang tools/install-cli.sh"
if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "$marker"
        echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    } >> "$HOME/.bashrc"
    echo "added ~/.local/bin to PATH in ~/.bashrc"
else
    echo "~/.bashrc already updated"
fi

echo
echo "Open a new WSL shell, then:  emerald run playground/main.em"
