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

Console styling slices 1 and 2 are implemented: `Console.Color`, `Console.style`, the twelve
basic helpers, and `Console.plain`. Styled values produce correctly nested ANSI SGR strings
when the execution-owned policy is forced on, and remain ordinary strings when it is off;
`plain` removes complete SGR sequences regardless of that policy, retaining other terminal
control text. The policy is not yet exposed through the CLI, environment, terminal detection,
or REPL; those belong to slice 3 of [`console-design-plan.md`](console-design-plan.md).

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

Console styling slice 2 is awaiting the user's commit decision. The next implementation slice
is real-terminal policy: CLI flags, environment precedence, terminal detection, Windows setup,
and REPL forwarding. It remains slice 3 of the Console plan.

## Deferred

- Taking `Trait.method` as a value remains rejected.
- Capturing a built-in function or method as a value, and variadic functions generally, remain
  rejected because no written function type describes them yet.
- Expanded `emerald.toml`, bounded implementation limits,
  networking, concurrency, generics, enum payloads, wider general overloading, and package
  management each need a separate design pass or a concrete program that motivates them.
- Braceless type bodies (10.6) are deferred, not rejected: 24 records what a proposal must
  answer (one canonical formatter output, one parsing mode, one way to teach a declaration).
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

Console styling slice 2 is implemented locally and uncommitted. With pinned Zig 0.16.0,
Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (97
linked files), `zig fmt --check src/*.zig`, and `git diff --check` passed. `Console.plain`
strips only complete `ESC[` + decimal-digit or semicolon + `m` sequences, and keeps cursor
controls, bare escapes, and incomplete or malformed sequences. Its checks live beside the
forced-color styling assertions and confirm that plain is also independent of the color policy.

Console styling slice 1 is committed as `0904ec7`. With pinned Zig 0.16.0,
`bash tools/check-toolchain.sh`, Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh` (97 linked files), `zig fmt --check src/*.zig`, and
`git diff --check` passed. The new `color/console-style` and `run/console-style-off`
expectations, plus the warning newly required by `diagnostics/nested-type-paths`, were read by
hand. `Console`'s prelude bodies must use `Emerald.Console` internally: otherwise a project
that declares its own `Console` captures them. The invalid-reserved-`Emerald` recovery path
needed a resolver guard for the same reason.

`Emerald` namespace slice 3 (documentation) is complete: rewrite-context 14.2, 15.1, and the
decision table, the projects guide, and the library inventory. `bash tools/check-doc-examples.sh`
and `git diff --check` passed, and both new snippets were run.

`Emerald` namespace slice 2 is complete. With pinned Zig 0.16.0, Debug and ReleaseSafe
`zig build test`, `zig build`, `bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`,
and `git diff --check` passed. New cases `run/emerald-builtins` and
`diagnostics/builtin-shadowing` were read by hand; `diagnostics/operators-shadowed-trait`
gained the new warning and its help now suggests `with Emerald.Ordered`, which was run to
confirm it reaches the built-in trait.

`Emerald` namespace slice 1 is complete. With pinned Zig 0.16.0, Debug and ReleaseSafe
`zig build test`, `zig build`, `bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`,
and `git diff --check` passed, with no leaks. New cases `run/emerald-namespace`,
`diagnostics/emerald-reserved`, `diagnostics/using-emerald-redundant`,
`diagnostics/project-reserved-directory`, and `diagnostics/project-lone-bad-directory` were
read by hand.

Empty bodies now format as `{ }` on the header's line (18.3). With pinned Zig 0.16.0, Debug and
ReleaseSafe `zig build test` (including a new Formatter test in both brace styles),
`zig build`, `bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`, and
`git diff --check` passed. `conformance/format/empty-bodies` was read by hand. Four examples
were reformatted: two for this rule, and three that had never been formatted (`} else {` on
one line in `hexdump.em` and the ledger).

Nested types slice 4 (documentation and integration) is complete. With pinned Zig 0.16.0,
Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (95
linked files), `zig fmt --check src/*.zig`, and `git diff --check` passed. A fuzz campaign
(`zig build fuzz -- 20260924 3000`) passed 3,000 cases, 436 executed; its new nested-types
template was run directly on both of its branches. The snippets added to rewrite-context 14.3
and the language guide were run, and a temporary nested enum in the prelude was checked for
the Console plan, then removed.

Nested types slice 3 (LSP) is complete. With pinned Zig 0.16.0, Debug and ReleaseSafe
`zig build test` (including new Lsp tests for nested symbols, per-segment definition,
references without enum-value duplicates, and completion's nested path key), `zig build`,
`bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`, and `git diff --check`
passed. Over JSON-RPC against `conformance/run/nested-types`: definition from every path
segment, cross-file references and rename from `main.em`, and completion while typing
(`Console.`, `Console.Color.`, `Ui.Console.Pair.`). A rename of the nested enum through a
same-spelled alias, and of a top-level type used as `Point?` and `List[Point]`, were applied
and the resulting programs run or check cleanly.

Nested types slice 2 (use by path) is complete. With pinned Zig 0.16.0, Debug and ReleaseSafe
`zig build test`, `zig build`, `bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`,
and `git diff --check` passed. New cases `run/nested-types`, `diagnostics/nested-type-paths`,
and `diagnostics/nested-type-privacy` were read by hand. An LSP smoke test sent hover,
definition, references, and completion at every third column of both files of
`run/nested-types`, plus document symbols, and got all 1,824 responses with a clean exit.

Nested types slice 1 (parse, format, register, check bodies) is complete. With pinned Zig
0.16.0, Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh`,
`zig fmt --check` on every changed source file, and `git diff --check` passed. New cases
`format/nested-types`, `diagnostics/nested-type-refusals`, `diagnostics/nested-type-clashes`,
and `diagnostics/nested-type-body`, plus a Formatter test covering both brace styles, were read
by hand. A 300-deep nesting stops at the parser's 256-level limit rather than recursing
without bound.

Nested types slice 0 (declaration/namespace name clash) is complete. With pinned Zig 0.16.0,
Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (94
linked files), `zig fmt --check src/Resolver.zig`, and `git diff --check` passed.
`conformance/diagnostics/namespace-clash` was read by hand before being accepted.

The type-declaration audit fixes are complete. With pinned Zig 0.16.0, Debug and ReleaseSafe
`zig build test`, `zig build`, `bash tools/check-doc-examples.sh` (93 linked files),
`zig fmt --check src/Formatter.zig src/Parser.zig`, and `git diff --check` passed. New cases
`conformance/format/enum-values` and `conformance/diagnostics/type-declaration-in-block` were
read by hand before being accepted.

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
