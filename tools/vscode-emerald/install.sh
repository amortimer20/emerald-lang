#!/usr/bin/env bash
# Packages and installs the VS Code extension. Re-run after changing the grammar or
# snippets — VS Code reads them from its own extensions folder, not from this repo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

npx --yes @vscode/vsce package --skip-license --out emerald-0.1.0.vsix
code --install-extension emerald-0.1.0.vsix --force

echo
echo "Installed. Now: Ctrl+Shift+P -> Developer: Reload Window"
