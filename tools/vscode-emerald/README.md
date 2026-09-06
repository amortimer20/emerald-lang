# Emerald for VS Code

Syntax highlighting and editing support for `.em` files. No build step — it is three
JSON files, and VS Code reads them directly.

## Install

```
cd tools/vscode-emerald
npx --yes @vscode/vsce package --skip-license --out emerald-0.1.0.vsix
code --install-extension emerald-0.1.0.vsix --force
```

Then **Ctrl+Shift+P → Developer: Reload Window**.

**Copying the folder into `~/.vscode/extensions` does not work.** Current VS Code keeps a
manifest at `~/.vscode/extensions/extensions.json` and only loads extensions listed
there, so a manually dropped folder is ignored silently — it will not appear in the
Extensions view and nothing will highlight. `code --install-extension` updates that
manifest, which is why packaging is the reliable route.

Re-run both commands after changing the grammar or snippets.

### If you work in WSL Remote

Grammars and snippets are UI-side contributions, so a local install applies to remote
windows too. If VS Code disagrees, run the same `code --install-extension` while
connected to WSL and it will install into `~/.vscode-server`.

The project itself does **not** need to live inside WSL — `/mnt/c` works, and only file
I/O is slower.

## What it does

**Highlighting** — keywords, types, strings with `#{}` interpolation highlighted as real
code, all three comment forms, `@attributes`, numbers, and ranges.

Two details specific to Emerald:

- **Predicate methods** (`empty?`, `even?`) are recognized as one token, `?` included, so
  the name highlights as a unit rather than a name plus a stray operator.
- **Keywords after a dot are not keywords.** `maybe.or(0)` highlights `or` as a method,
  not as the logical operator — because in Emerald it is one (member names live in their
  own namespace). A naive grammar gets this wrong; every rule here uses `(?<!\.)`.

**Editing** — `#` toggles line comments, `#[ ]#` toggles blocks, brackets auto-close, and
`##` doc comments continue onto the next line when you press Enter.

## The file icon

`icons/file_type_emerald.svg` is a file-type icon for the
[vscode-icons](https://marketplace.visualstudio.com/items?itemName=vscode-icons-team.vscode-icons)
extension, which is separate from this one and reads custom icons from a fixed folder.

Copy it into VS Code's user directory:

```
# Windows
copy icons\file_type_emerald.svg "%APPDATA%\Code\User\vsicons-custom-icons\"

# Linux
cp icons/file_type_emerald.svg ~/.config/Code/User/vsicons-custom-icons/

# macOS
cp icons/file_type_emerald.svg ~/Library/Application\ Support/Code/User/vsicons-custom-icons/
```

Then add the association to your **user** `settings.json`:

```json
"vsicons.associations.files": [
    { "icon": "emerald", "extensions": ["em"], "format": "svg" }
]
```

Finally **Ctrl+Shift+P -> Apply Icons Customization**, which rebuilds vscode-icons'
manifest and reloads the window. Nothing changes until that command is run.

The `emerald` in the association is what names the file: vscode-icons prefixes it with
`file_type_`, so the icon must be `file_type_emerald.svg` exactly. A light-theme variant
would be `file_type_light_emerald.svg`; there is not one, because the green reads on both
grounds.

`icons/emerald.svg` is the same drawing at a smaller scale and is not used by anything --
kept as the general-purpose logo.

## What it does not do yet

No language server, so there is no completion, no hover, no go-to-definition, and no
inline errors. Diagnostics appear in the terminal when you run a file.

The compiler already computes everything an LSP would need — types, narrowing, symbol
resolution, and the diagnostics themselves. Wiring it to the Language Server Protocol is
a separate project, not more grammar work.
