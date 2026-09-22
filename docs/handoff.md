# Current handoff

Updated: 2026-09-22. This is the live status a session starts from. Keep it to the current
milestone, next work, active rough edges, and recent validation. Completed-slice narrative
belongs in [`docs/journal.md`](journal.md); settled language behavior belongs in
[`docs/rewrite-context.md`](rewrite-context.md).

## Current status

The Zig rewrite implements the current rewrite-context language surface: control flow,
functions, optionals, collections, Unicode strings, structs, classes, inheritance, traits,
enums, typed errors, projects/namespaces, ranges and slicing. The formatter, REPL, and LSP
diagnostics, symbols, format-on-save, hover, go to definition, find references, rename, and
completion are complete.

The filesystem library supports UTF-8 and binary whole-file operations plus streamed text and
binary reads/writes. `File.open` returns a read-only `FileHandle`; `File.create` returns a
write-only `FileWriter`; their block forms guarantee closure. `Bytes` provides immutable raw
data. Filesystem failures use `FileError`.

Release hardening is in place: CI runs Debug and ReleaseSafe tests on Ubuntu, macOS, and
Windows; the fuzz runner checks, formats, and boundedly executes generated clean programs;
and allocator-failure coverage reaches the frontend pipeline and interpreter.

Arithmetic operator annotations are complete through their first two committed slices:
`d73ede4` adds `@operator("+")`/`-`/`*`/`/` parsing, checking, formatting, and execution;
`f2dfac2` adds disjoint registrations, inheritance-aware static selection with normal virtual
dispatch, and compound assignment. The current, uncommitted retirement slice removes the four
prelude arithmetic authorization traits, leaving annotation registration as the only user-type
arithmetic mechanism; `Ordered` remains the comparison trait. Its behavior, canonical-name
rule, inheritance semantics, and limitations are recorded in §11.5 and §22 of the rewrite
context.

## Next step

Review and commit the completed arithmetic-trait retirement slice when the user authorizes it.

## Deferred

- Taking `Trait.method` as a value remains rejected.
- Capturing a built-in function or method as a value, and variadic functions generally, remain
  rejected because no written function type describes them yet.
- Diagnostics/`emerald explain`, expanded `emerald.toml`, bounded implementation limits,
  networking, concurrency, generics, enum payloads, wider general overloading, and package
  management each need a separate design pass or a concrete program that motivates them.

## Active rough edges

- Runtime failures currently share `RuntimeError` except `AssertionError` and `FileError`.
- Capture and definite-assignment analysis remains conservative in several known ways.
- Assignment through a call result and assignment to a type-level field through a namespace
  remain unsupported.
- Display/recursive dictionary-key checks have a 256-path limit; character indexing is linear;
  repeated dictionary or set deletion is quadratic.
- `emerald.toml` currently recognizes only `brace_style` with a deliberately small scanner.

## Validation and repository state

The retirement slice passed Debug and ReleaseSafe `zig build test`, `zig build`, `bash
tools/check-doc-examples.sh` (92 linked files), and `git diff --check` using pinned Zig 0.16.0.
Preserve the unrelated untracked
`emerald-file-writer-streaming-closed.txt` artifact.
