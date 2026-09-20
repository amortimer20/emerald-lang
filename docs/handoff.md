# Current handoff

Updated: 2026-09-20. This is the live status a session starts from. Keep it to the current
milestone, next work, active rough edges, and recent validation. Completed-slice narrative
belongs in [`docs/journal.md`](journal.md); settled language behavior belongs in
[`docs/rewrite-context.md`](rewrite-context.md).

## Current status

The Zig rewrite implements the current rewrite-context language surface: control flow,
functions, optionals, collections, Unicode strings, structs, classes, inheritance, traits,
enums, typed errors, projects/namespaces, range values and slicing. The formatter, REPL, and
the LSP's first slice (diagnostics, document symbols, format on save) are complete.

The standard library's whole-file filesystem area is complete. `File`, `Directory`, and
`Path` provide UTF-8 text I/O, recursive/idempotent directory creation, empty-only directory
deletion, listing, and lexical path helpers. Filesystem failures use `FileError`. Streaming,
binary I/O, and recursive deletion remain deferred.

Release hardening is in place: CI runs Debug and ReleaseSafe tests on Ubuntu, macOS, and
Windows; the fuzz runner checks, formats, and boundedly executes generated clean programs;
and allocator-failure coverage reaches the frontend pipeline and interpreter. The checker also
warns for `is` tests known true and for bounded known-false cases: unrelated concrete classes,
or a class whose declared subclasses never adopt the tested trait. Trait-typed values, structs,
and enums remain outside that false-result proof.

Language and library documentation is complete through the pages listed in
[`docs/language/README.md`](language/README.md) and
[`docs/library/inventory.md`](library/inventory.md). `tools/check-doc-examples.sh` verifies
their linked Emerald examples after a build.

`List.remove_if(block)` is implemented (8.5 had named it as design intent without building
it) — `reject`'s in-place sibling, removing every element the block accepts.

Numeric `.format()`/`to_string(base:)` (15.5's sketch) is implemented: `Int.to_string` takes
a named, defaulted `base` (2 through 36); `Int.format`/`Float.format` add thousands
separators, and `Float.format` also takes a named, defaulted `decimal_places` for fixed-point
rounding. Both methods are the first built-ins with real named/defaulted arguments outside a
declared function, method, or type, so `typeOfMethodCall`'s general "a built-in takes no
names" rejection now carves out this one exception.

The `Textual` trait (15.1) is implemented, as the sixth prelude trait in 11.5's family
rather than as new display machinery. A type adopting it renders through its own
`to_string()` in `print`, `write`, and interpolation, and everywhere the value appears,
because `Value.writeThrough` carries a comptime display context through the whole walk;
`{}` keeps diagnostics on the field-based form so building a failure never runs a program's
own code. The checker warns when a type declares `to_string` without adopting the trait.

The program entry point (14.1) is complete: `Program.arguments` is a `List[String]` built
from whatever follows `--` on the command line (`emerald <command> <file.em> -- <args>...`,
accepted by `check`/`run`/`test` alike, though only `run`/`test` populate it), and a bare
`return` at the entry file's own top level ends the program successfully after pending
`finally` blocks, exactly like reaching the end of the file. `exit(code)`'s plumbing needed
no work; it was already complete.

The first real-program shakedown is complete:
[`examples/ledger/`](../examples/ledger/) is a persisted personal-finance CLI with `add`,
`list`, `summary`, and `category` commands. It uses a deliberately simple tab-delimited
store through `File`/`Directory`/`Path`, command-line arguments, structs and `Textual`,
collection transforms, numeric formatting, and typed input/store errors. Its end-to-end
workflow found no language defect; it did catch an ordinary API spelling mistake while being
written (`starts_with?`, not `starts_with`).

The LSP's second phase has begun: inferred-type hover is implemented. It needed two things
the first slice's file-scoped features (diagnostics, document symbols, format on save) never
did — `Checker.zig`'s `expression_types` (every expression's type, by expression, via a new
`emerald.analyzeProject` that exposes checking's full detail without executing anything) and
a document's whole project (14.1), so a file checked alone no longer misses its own project's
other declarations. `Lsp.zig`'s `loadDocument` reads a document's project from disk,
substituting the editor's own buffer for the open file — the first slice's "never touches
disk" now has this one exception. Diagnostics publishing was upgraded the same way, fixing a
latent gap where opening one file of a multi-file project showed false "not defined" errors
for anything it referenced from a sibling file. Also fixed in passing: the LSP was publishing
every warning as an LSP "Error"; `Diagnostic.Severity` existed by the time that code was
written but the mapping was never updated.

Windows CI is green again. Two independent bugs, both host-specific, were hiding behind
`zig build test` passing everywhere else: `Path.join` (15.3) used `std.fs.path.join`, which
joins with the host's native separator, so the same Emerald program printed `\`-joined paths
on Windows and `/`-joined paths elsewhere — real paths still worked (Windows accepts `/` too;
`std.os.windows.normalizePath` converts it before the Win32 call), but the *lexical* contract
`docs/library/path.md` documents cannot mean "whatever the host does" and still be tested by
one golden file shared across all three CI platforms. `Path.join` and `Directory.list`'s
internal path-building now both go through a new `joinPathParts` (`Interpreter.zig`) that
always joins with `/`. Separately, a Debug-only Zig test built an Emerald program by splicing
a real absolute path straight into a string literal; on Windows that path contains `\`, which
the Emerald lexer reads as an escape introducer, so the test failed to parse rather than
testing what it meant to. Fixed by escaping the path as an Emerald string literal before
splicing it in (`escapeAsEmeraldStringLiteral` in `src/emerald.zig`).

## Next step

A 2026-09-20 roadmap review triaged prior "what's next" suggestions from both agents against
the current binary. Closed and no longer live: per-family runnable examples, `!`/optional/
callback/raise labeling, conformance-programs-as-executable-examples, the filesystem design,
the five maintainability findings (retired in `6a6a718`), the program entry point, and the
opportunistic trait `is` analysis (streaming I/O and the bounded implementation limits below
were bundled with it but were not done, and were not promoted to a named next step; nothing
currently motivates either). What's open, in recommended order, none yet authorized to start:

1. The rest of the LSP's second phase: go to definition and find references next (sharing
   hover's foundation plus a name-to-declaration index), then safe rename (built on find
   references), then completion last (its own parser recovery strategy, the one piece that
   is not "more of the same" — see `Lsp.zig`'s header).

Named but unordered: `emerald explain`/diagnostic polish; a custom equality/hashing design
pass, the natural sibling to `Textual`/`Ordered`; streaming/binary file I/O and recursive
directory delete (deferred out of the filesystem slice; recursive delete has no design
blocker, streaming/binary I/O needs its own design pass first). The big deferred-features
list (generics, enum payloads, wider operator overloading, package manager, concurrency)
stays last by design — those are large design commitments, not implementation backlog. This
is context, not authorization: follow the user's active request rather than starting any of
it unprompted.

## Deferred

Language behavior not yet built, confirmed still true against the current binary (not
regressions from recent work — each checked directly, including against the commit before
this session's changes where that mattered):

- Taking `Trait.method` as a value is rejected with a diagnostic rather than supported.
- Capturing a built-in function (`print`) or method (`numbers.append`) as a value, and
  variadic functions generally, are rejected — no written function type describes them yet.
- A module-level lambda or nested function that reads a module variable unassigned at its
  own *declaration* site is flagged even when every actual call happens after the variable
  is assigned; the capture check uses declaration-site state rather than call-site order.
  Predates this session's changes.

## Active rough edges

- Runtime failures currently share `RuntimeError` except `AssertionError` and `FileError`.
  Add a focused subclass only with the feature that needs programs to distinguish it.
- A mixed sibling-class list needs an explicit common base or trait annotation:
  `const pets: List[Animal] = [Dog(), Cat()]`.
- Capture and definite-assignment analysis remains conservative in several known ways:
  it tracks lambda assignments by bare name, over-approximates type setup/default reads, and
  does not follow a function reached through a value.
- Assignment through a call result and assignment to a type-level field through a namespace
  remain unsupported. Reading and calling through namespaces work.
- A few bounded implementation limits are intentional for now: display and recursive
  dictionary-key checks use a 256-type/object path; character indexing is linear; repeated
  dictionary or set deletion is quadratic.
- `emerald check` on a missing file exits `64`; section 18.1 does not yet specify that case.

## Validation and repository state

The latest completed slices, including the program entry point, the ledger shakedown, the
trait-aware impossible-type-test warning, LSP hover, and the Windows path/lexer fix above,
passed `bash tools/check-toolchain.sh`, `zig build test` in Debug and ReleaseSafe (359/359
tests), `bash tools/check-doc-examples.sh` after `zig build`, and `git diff --check` with
pinned Zig 0.16.0 — run on Linux; the Windows-specific fixes could not be verified on real
Windows locally, so CI is the first real check of them. The working tree was clean after
commit `2407bef` (`Implement LSP hover, and give the language server project awareness`)
before this pass.

When a change affects behavior, prefer end-to-end conformance coverage. Before handoff, run
the checks appropriate to the change and update this file's status rather than adding a
session diary.
