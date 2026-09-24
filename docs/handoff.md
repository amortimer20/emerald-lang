# Current handoff

Updated: 2026-09-23. This is the live status a session starts from. Keep it to the current
milestone, next work, active rough edges, and recent validation. Completed-slice narrative
belongs in [`docs/journal.md`](journal.md); settled language behavior belongs in
[`docs/rewrite-context.md`](rewrite-context.md).

## Current status

The Zig rewrite implements the current rewrite-context language surface: control flow,
functions, optionals, collections, Unicode strings, structs, classes, inheritance, traits,
enums, typed errors, projects/namespaces, ranges and slicing. The formatter, REPL, and LSP
diagnostics, symbols, format-on-save, hover, go to definition, find references, rename, and
completion are complete.

Inline `if condition then value else value` is now implemented, closing a gap that the
design and language guide had incorrectly described as already available. It supports
lazy branch evaluation, compatible result types, branch-local narrowing, expected types
for collections/lambdas, and use in returns, interpolation, and nested expressions.
Formatting and LSP expression traversal cover it; `return if condition` remains a guard.

The native `Random` dispatch collision found during that work is fixed: resolved user
methods take precedence over native name-based routing. User-defined `next`, `choose`,
and `shuffle!` now follow ordinary mutation, inheritance, and optional-call semantics.

The filesystem library supports UTF-8 and binary whole-file operations plus streamed text and
binary reads/writes. `File.open` returns a read-only `FileHandle`; `File.create` returns a
write-only `FileWriter`; their block forms guarantee closure. `Bytes` provides immutable raw
data. Filesystem failures use `FileError`.

Release hardening is in place: CI runs Debug and ReleaseSafe tests on Ubuntu, macOS, and
Windows; the fuzz runner checks, formats, and boundedly executes generated clean programs;
and allocator-failure coverage reaches the frontend pipeline and interpreter.

The command-line contract has focused end-to-end coverage in `build.zig`: `check` completes
analysis without executing valid entry code; `run` stops before execution on source errors,
but executes warning-only programs while retaining status `1`; `run` and `test` receive
arguments after `--`, while `check` rejects arguments it cannot use; and `test` distinguishes
failed tests. The CLI has concise global and command-specific help, specific recovery text for
bad invocations, formatter change reporting, and REPL `:help`/`:quit`; `lsp` remains available
through its dedicated help but is intentionally absent from the interactive command list.
Their substantive REPL and LSP protocol behavior remains covered in their own Zig modules.
Emerald 0.4.0 is published; `v0.5.0` is tagged locally at `c0dea26` but not pushed or published.
The 0.5.0 tag includes inline `if` expressions and the Random dispatch fix.
Development binaries now identify themselves as `Emerald 0.6.0-dev`;
release automation passes the pushed `vX.Y.Z` tag through the build so a distributed binary
reports that exact version.
Release preparation now also packages and smokes the binary's version, `help`, `check`, `run`,
`test`, `format --check`, `explain`, and clean REPL exit on every release platform. A manual
release-workflow dispatch builds and verifies artifacts but cannot publish them; publishing
requires a `vX.Y.Z` tag.
The root README is now a user-facing entry point: a first program, installation, common
commands, source build, and learning links. It uses the shared Emerald SVG mark and leaves
implementation history, agent instructions, and source-tree inventory to their proper docs.

The first diagnostic-explainer slice is complete. CLI diagnostics label four common,
curated problems with stable codes: undefined names, declaration type mismatches, const
reassignment, and unknown members. `emerald explain <code>` prints a short worked
example for each. Bare `emerald explain` remains deferred rather than guessing at a
"most recent" diagnostic across independent command invocations; editor/LSP diagnostic codes
and a broader catalog remain later work. If that catalog grows, one typed code registry and
generated reference page replace the current small hand-maintained catalog.

Arithmetic operator annotations are complete:
`d73ede4` adds `@operator("+")`/`-`/`*`/`/` parsing, checking, formatting, and execution;
`f2dfac2` adds disjoint registrations, inheritance-aware static selection with normal virtual
dispatch, and compound assignment; `2a9676a` retires the four prelude arithmetic authorization
traits. Annotation registration is the only user-type arithmetic mechanism; `Ordered` remains
the comparison trait. Operator-token go-to-definition and find references follow the same
static selection and reach the registered method. Its behavior, canonical-name rule,
inheritance semantics, and limitations are recorded in §11.5 and §22 of the rewrite context.
Operator symbols are navigation/reference sites, not renameable identifiers; renaming their
method changes only ordinary identifier uses.

## Next step

No implementation slice is active. Choose the next task from the deferred/features backlog
only with user authorization.

## Deferred

- Taking `Trait.method` as a value remains rejected.
- Capturing a built-in function or method as a value, and variadic functions generally, remain
  rejected because no written function type describes them yet.
- Expanded `emerald.toml`, bounded implementation limits,
  networking, concurrency, generics, enum payloads, wider general overloading, and package
  management each need a separate design pass or a concrete program that motivates them.
- Official platform libraries are a product direction, not an implemented API: `Console`
  (styled immediate terminal output and line-oriented interaction) is the first candidate;
  `Tui`, `Graphics`, `Gui`, `Audio`, and `Game` each need their own design pass and real
  beginner-program motivation.
- A generated diagnostic-code registry and reference page wait until the explainer catalog is
  large enough to justify their extra machinery.

## Active rough edges

- Runtime failures currently share `RuntimeError` except `AssertionError` and `FileError`.
- Capture and definite-assignment analysis remains conservative in several known ways.
- Assignment through a call result and assignment to a type-level field through a namespace
  remain unsupported.
- Display/recursive dictionary-key checks have a 256-path limit; character indexing is linear;
  repeated dictionary or set deletion is quadratic.
- `emerald.toml` currently recognizes only `brace_style` with a deliberately small scanner.

## Validation and repository state

The Random dispatch fix is complete. With pinned Zig 0.16.0, Debug and
ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (93 linked
files), `zig fmt --check src/Interpreter.zig`, and `git diff --check` passed. The new
`conformance/run/random-method-names.em` also ran directly with its output reviewed:
user structs, inherited/overridden class methods, captured methods, and absent optional
receivers work alongside seeded Random operations and ordinary `List.shuffle!()`.
The platform-library roadmap is recorded in a separate documentation commit. The fix is committed as
`c0dea26`, tagged locally as `v0.5.0`; publishing still requires a push.

The inline-if slice is complete. With pinned Zig 0.16.0, it passed Debug
and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (93 linked
files), Zig formatting checks, and `git diff --check`. A bounded fuzz campaign
(`zig build fuzz -- 20260923 2000`) passed 2,000 cases, with 247 reaching execution;
the generator now includes inline conditionals. Focused conformance covers execution,
diagnostics, and formatter idempotence; Zig tests cover return guards, mutation, nesting
limits, allocation failures, and LSP traversal. The platform-library roadmap is recorded
separately from the inline-if commit. Pushing the commits and release tag is left to the user.

The operator-annotation feature passed Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh` (92 linked files), and `git diff --check` using pinned Zig
0.16.0. Its final integration audit found no old syntax in the fuzz generator; the LSP has
named-method, operator-token go-to-definition, and operator-token reference coverage.
Rename rejects an operator-token cursor and excludes operator-token locations from method
rename edits.
The command-contract QA and interactive-polish slice passed Debug and ReleaseSafe `zig build
test`, `zig build`, `bash tools/check-doc-examples.sh` (92 linked files), and `git diff --check`
with pinned Zig 0.16.0. The formatter's changed-file output and rewrite summary were also
checked directly against a fresh temporary source file.
The diagnostic explainer passed Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh` (92 linked files), and `git diff --check` with pinned Zig 0.16.0.
The closed-FileWriter conformance case now cleans up its own temporary file in `finally`, so
the suite leaves no generated artifact in the repository root.
The version command passed Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh` (92 linked files), and `git diff --check` with pinned Zig 0.16.0.
The 0.4 release-readiness changes passed Debug and ReleaseSafe `zig build test`,
`zig build`, `bash tools/check-doc-examples.sh` (92 linked files), and `git diff --check` with
pinned Zig 0.16.0. A locally built `ReleaseSafe`, baseline-CPU `Emerald 0.4.0` tar archive was
unpacked and successfully exercised through every release smoke command, including a passing
`@test` function. GitHub Actions then built, package-smoked, checksummed, and published all
three 0.4.0 platform assets successfully.
The pending README refresh passed `bash tools/check-doc-examples.sh` (92 linked files) and
`git diff --check`; every relative link in its user-facing path was also checked directly.
