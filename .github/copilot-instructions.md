# Emerald development instructions

Emerald is an experimental, statically typed language implemented from scratch in Zig.
Its language-design authority is `docs/rewrite-context.md`; do not infer rewrite behavior
from `legacy/dotnet-v0/`, which is historical evidence only. Start a session by reading
`AGENTS.md`, `docs/handoff.md`, and the relevant sections of the rewrite context. The
handoff records the active milestone, while the working tree and Git history are
authoritative if it has become stale.

## Toolchain and commands

Zig `0.16.0` is pinned in both `mise.toml` and `toolchain/zig-version.txt`. Confirm the
selected compiler and its required APIs before changing Zig code:

```bash
bash tools/check-toolchain.sh
```

| Purpose | Command |
| --- | --- |
| Build the CLI | `zig build` |
| Run all Zig, conformance, REPL, LSP, and CLI-contract tests | `zig build test` |
| Run one Zig test by name | `zig test src/Source.zig --test-filter 'valid UTF-8 reports no invalid span'` |
| Run/check/test an Emerald program | `zig build run -- run path/to/file.em` / `zig build run -- check path/to/file.em` / `zig build run -- test path/to/file-or-project` |
| Check formatting without writing | `zig build run -- format --check path/to/file-or-project` |
| Run Unicode database conformance after regenerating tables | `zig build unicode-conformance -Doptimize=ReleaseSafe -- path/to/unicode-database` |

`zig build test` intentionally has multiple roots: the frontend library, backend-neutral
conformance runner, REPL, LSP, and real CLI contract tests. For a focused implementation
test, use `zig test` against the owning source file and `--test-filter`. Conformance cases
cannot currently be filtered by the build step; exercise one manually with the built CLI,
for example `zig build run -- check conformance/diagnostics/your-case.em`.

## Architecture

`src/main.zig` is the CLI boundary. It loads an Emerald `Project`, calls the frontend
library, and renders its canonical diagnostics. The supported implementation commands are
`check`, `run`, `test`, `format`, `repl`, and `lsp`; preserve their stable status behavior.

`src/emerald.zig` is the frontend façade and stage coordinator:

1. `Project.zig` loads either one `.em` file or every `.em` file beneath the directory
   containing the invoked `main.em`; directory names create namespaces.
2. `Source.zig`, `Lexer.zig`, `Parser.zig`, `Resolver.zig`, and `Checker.zig` process every
   project file stage-by-stage. The embedded `src/prelude.em` is added only after user files.
   Diagnostics stop before later stages to avoid cascades.
3. `Interpreter.zig` evaluates checked programs; `Heap.zig` owns reference-counted,
   copy-on-write collection/string storage and cycle collection. `Value.zig` represents
   runtime values, while `Type.zig` is the static type model.
4. `Formatter.zig` uses only lexing and parsing, so syntactically valid but unchecked code
   can be formatted. `Repl.zig` and `Lsp.zig` are separate roots because they are siblings
   of the CLI, not imports of the library root.

The main pipeline runs on a deliberately large-stack thread. Preserve parser nesting bounds
and interpreter stack accounting when adding recursive behavior; do not add a fallback to
the caller's stack.

## Language behavior and test conventions

Language semantics and diagnostic wording are product behavior. Implement changes through
the full path—syntax, AST, resolution, checking, runtime/formatting as applicable—and add
backend-neutral coverage in `conformance/` when the behavior could differ on a future
backend.

`conformance/README.md` defines the golden-case layout:

| Directory | Expected result |
| --- | --- |
| `lexical/` | Tokenizes without diagnostics |
| `diagnostics/` | Exact `check` diagnostic text in `.expected` |
| `run/` | Exact standard output in `.expected` |
| `runtime-errors/` | Exact runtime diagnostic in `.expected` |
| `format/` | Exact formatted source in `.expected`, including formatter idempotence |

A project case is a directory containing `main.em`; its sibling `.expected` covers the
whole project. `.input` files supply standard input. Generate golden files from inside
`conformance/` so diagnostic paths remain relative, then review the generated text before
committing it.

Source text is UTF-8, with Unicode-aware identifiers, grapheme behavior, normalization, and
case mapping. `src/unicode/tables.zig` is generated data: regenerate it with
`tools/unicode/fetch.sh` and `tools/unicode/generate.zig`, format it with `zig fmt`, and
then run the Unicode conformance command rather than editing it by hand.

Use the language conventions in the rewrite context: types and traits use `PascalCase`;
variables, fields, parameters, functions, methods, constants, and enum values use
`snake_case`; Boolean methods end in `?`; leading `_` denotes privacy. Treat `const`
collection contents and value-semantics/copy-on-write rules as checker and runtime behavior,
not merely implementation details.

Before handing off, update `docs/handoff.md` with the current milestone, completed work,
next step, validation, blockers, and pending changes; replace stale status rather than
appending a diary.
