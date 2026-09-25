# Current handoff

Updated: 2026-09-25. This is the live status a session starts from. Keep it to the current
milestone, next work, active rough edges, and recent validation. Completed-slice narrative
belongs in [`docs/journal.md`](journal.md); settled language behavior belongs in
[`docs/rewrite-context.md`](rewrite-context.md).

## Current status

The Zig rewrite implements the current rewrite-context language surface: control flow,
functions, optionals, collections, Unicode strings, structs, classes, inheritance, traits,
enums, typed errors, projects/namespaces, ranges and slicing. The formatter, REPL, and LSP
diagnostics, symbols, format-on-save, hover, go to definition, find references, rename, and
completion are complete.

Built-ins live in a writable, implicitly imported `Emerald` namespace (14.2, 15.1): a project
name always wins over a built-in, with a warning, and the built-in stays reachable as
`Emerald.File`, `Emerald.print`, or `Emerald.Math.pi`. `Emerald` is the one reserved name. See
[`emerald-namespace-design-plan.md`](emerald-namespace-design-plan.md).

Nested types (14.3) are implemented: a struct, class, or enum can declare types inside its
braces, reached by path (`Console.Color.red`, `Ui.Console.Pair`, `using Color =
Console.Color`), with privacy by 10.5's braces rule and full LSP support. The spec had called
them settled while nothing implemented them; see
[`nested-types-design-plan.md`](nested-types-design-plan.md) for what was decided and why. A
module-level declaration may no longer share a directory namespace's name.

Console styling (15.6), Emerald's first official platform library, is complete through all
four planned slices: `Console.Color`, `Console.style`, the twelve basic helpers,
`Console.plain`, and real execution policy. `run` and `test` accept
`--color=auto|always|never`; `NO_COLOR`, `FORCE_COLOR`, `TERM=dumb`, stdout capability, and
Windows VT setup resolve in that settled order; the REPL follows the same automatic policy.
[`docs/library/console.md`](library/console.md), the inventory entry, rewrite-context 15.6
and its decision-table rows, and [`examples/console.em`](../examples/console.em) document it.
One-shot layout widgets (`Table`, `Panel`) and line-oriented interaction (prompts,
multi-select) are later slices of the same library, not a separate `Tui`; see
[`console-design-plan.md`](console-design-plan.md).

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
Emerald 0.5.0 is published (tag `v0.5.0` at `c0dea26`, released 2026-09-24); it includes
inline `if` expressions and the Random dispatch fix.
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

Dates and times (rewrite-context 15.8) are being implemented from
[`date-time-design-plan.md`](date-time-design-plan.md). The user accepted every decision in
it. Slice 1 (`Date`, `Duration`, `Weekday`, `DateTimeError`, and the named-unit diagnostic)
is done. Slice 2, `Time` and `DateTime`, is next. It follows the same approach: pure
Emerald in `src/prelude.em`, and `Emerald.`-qualified names inside prelude bodies. Library
pages and an example program come in slice 6, as the plan says.

Console's remaining scope (`Table`/`Panel` widgets, prompts, multi-select) comes after dates
and times and needs its own design proposal (24). `Tui`, `Graphics`, `Gui`, `Audio`, and
`Game` are parked rather than on the roadmap.

## Deferred

- Taking `Trait.method` as a value remains rejected.
- Capturing a built-in function or method as a value, and variadic functions generally, remain
  rejected because no written function type describes them yet.
- Expanded `emerald.toml`, bounded implementation limits, concurrency, generics, enum
  payloads, wider general overloading, and package management each need a separate design
  pass or a concrete program that motivates them.
- The standard-library backlog is recorded in rewrite-context 15.7: date/time (highest
  priority, no new infrastructure needed), regular expressions (15.4 already designed),
  JSON, a synchronous networking client, and what is deliberately not planned.
- Braceless type bodies (10.6) are deferred, not rejected: 24 records what a proposal must
  answer (one canonical formatter output, one parsing mode, one way to teach a declaration).
- `Console`'s remaining scope — `Table`/`Panel` layout widgets and line-oriented interaction
  (prompts, multi-select) — remains undesigned. `Tui`, `Graphics`, `Gui`, `Audio`, and `Game`
  are parked rather than on the roadmap: a full-screen terminal library needs raw-mode input
  and a redraw loop, and the other three need native platform bindings with no extension
  mechanism to plug them in and likely their own repos once a package manager exists.
- A generated diagnostic-code registry and reference page wait until the explainer catalog is
  large enough to justify their extra machinery.

## Active rough edges

- Runtime failures currently share `RuntimeError` except `AssertionError`, `FileError`, and
  `DateTimeError`.
- Capture and definite-assignment analysis remains conservative in several known ways.
- Assignment through a call result and assignment to a type-level field through a namespace
  remain unsupported.
- Display/recursive dictionary-key checks have a 256-path limit; character indexing is linear;
  repeated dictionary or set deletion is quadratic.
- `emerald.toml` currently recognizes only `brace_style` with a deliberately small scanner.

## Validation and repository state

Dates and times slice 1 is committed after its own checker performance fix. With pinned
Zig 0.16.0, Debug and ReleaseSafe `zig build test`, `zig build`, `zig fmt --check
src/*.zig`, `bash tools/check-doc-examples.sh` (100 linked files), `git diff --check`, and a
fuzz campaign (`zig build fuzz -- 20260925 3000`: 3,000 cases, 402 executed) passed. The new
conformance cases `run/date-basics`, `run/duration-basics`, `run/date-errors`,
`runtime-errors/date-invalid-day`, and `diagnostics/time-units-named` were checked by hand,
including the weekday of 0001-01-01, month-end clamping, and large-divisor `Duration`
division against Python.

Startup cost was measured as the plan asked. A ReleaseSafe `print(1)` took 5.0 ms before
this work. The new prelude code first pushed that to 13.6 ms, because the checker copied the
whole module scope into every function body it checked and snapshotted that copy at every
branch. Copying only variables brought it to 5.5 ms (3.3 ms without the date code).

All of this work is pushed to `claude/adoring-pasteur-wz5l0h`. Each earlier slice's validation
is recorded in [`journal.md`](journal.md) and its commit message.

Cloud sessions cannot reach ziglang.org. The pinned Zig 0.16.0 comes from the `ziglang==0.16.0`
PyPI wheel instead (`pip download ziglang==0.16.0 --no-deps`, unzip, and put `ziglang/` on
`PATH`), and `bash tools/check-toolchain.sh` accepts it.
