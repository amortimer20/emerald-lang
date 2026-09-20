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
warns for `is` tests known true and for the bounded known-false case of unrelated concrete
classes. Traits deliberately receive no false-result warning because a subclass may adopt a
trait independently.

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

## Next step

A 2026-09-20 roadmap review triaged prior "what's next" suggestions from both agents against
the current binary. Closed and no longer live: per-family runnable examples, `!`/optional/
callback/raise labeling, conformance-programs-as-executable-examples, the filesystem design,
the five maintainability findings (retired in `6a6a718`), and the program entry point. What's
open, in recommended order, none yet authorized to start:

1. The LSP's second phase (hover, go-to-definition, find references, safe rename,
   completion — see the journal's LSP notes) — highest day-to-day payoff, lowest design
   risk, since the first slice already proved the architecture.

Named but unordered: `emerald explain`/diagnostic polish; a custom equality/hashing design
pass, the natural sibling to `Textual`/`Ordered`; the always-false `is` warning for traits;
streaming/binary file I/O and recursive directory delete (deferred out of the filesystem
slice). The big deferred-features list (generics, enum payloads, wider operator overloading,
package manager, concurrency) stays last by design — those are large design commitments, not
implementation backlog. This is context, not authorization: follow the user's active request
rather than starting any of it unprompted.

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

The latest completed slices, including `format`/`to_string(base:)`, `Textual`, and the
program entry point, passed `bash tools/check-toolchain.sh`, `zig build test` in Debug and
ReleaseSafe, `bash tools/check-doc-examples.sh` after `zig build`, and `git diff --check`
with pinned Zig 0.16.0. The working tree was clean after commit `2d26af3` (`Update handoff with the triaged
roadmap`) before this pass.

When a change affects behavior, prefer end-to-end conformance coverage. Before handoff, run
the checks appropriate to the change and update this file's status rather than adding a
session diary.
