# Current handoff

Updated: 2026-09-20. This is the live status a session starts from. Keep it to the current
milestone, next work, active rough edges, and recent validation. Completed-slice narrative
belongs in [`docs/journal.md`](journal.md); settled language behavior belongs in
[`docs/rewrite-context.md`](rewrite-context.md).

## Current status

The Zig rewrite implements the current rewrite-context language surface: control flow,
functions, optionals, collections, Unicode strings, structs, classes, inheritance, traits,
enums, typed errors, projects/namespaces, range values and slicing. The formatter, REPL, and
the LSP's first two phases (diagnostics, document symbols, format on save, hover, go to
definition, find references, rename, and completion) are complete, with each phase's own known
gaps listed under "Active rough edges" below. Brace style (3.4) is a per-project choice, read
from `emerald.toml`; see below for what changed and why.

The standard library's whole-file filesystem area is complete. `File`, `Directory`, and
`Path` provide UTF-8 text I/O, recursive/idempotent directory creation, empty-only and
recursive/idempotent directory deletion, listing, and lexical path helpers. Filesystem
failures use `FileError`. Streaming and binary I/O remain deferred.

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

Go to definition is implemented, the next piece of the LSP's second phase named below. It
started as an unfinished draft from another agent (Google Antigravity, trialed separately)
that hit its usage limit mid-task; the draft didn't compile and was reviewed and hardened
before landing. `Resolver.zig`'s hoisting now records `facts.declarations` (every module-level
symbol's own name span), `facts.expression_targets` (every name read's resolved declaration),
and `facts.assignment_targets` (same, for assignment destinations) — the same fact-gathering
pass, extended rather than re-walked. `Lsp.zig` answers `textDocument/definition` by checking,
in order: the innermost expression at the cursor (a name or member access, plus a call's own
callee — see below), an assignment destination, a written type annotation, and the declaration
name itself. Fixed during review: a compile error from assuming `Type` represented `T?` as a
wrapping `Kind` rather than the plain bool flag it is; a fixed 256-byte key buffer that
silently truncated a long namespaced-type-plus-member lookup instead of allocating like
`Resolver.methodKey` does; three copies of the same "which file owns this binding" computation
factored into one `targetFileFor`; and `pathToUri` silently coercing an unexpectedly-relative
path into a fake-absolute one instead of asserting the invariant that it never receives one.
Also fixed, found only by an end-to-end smoke test rather than by reading the diff: a plain
function or constructor call's own name (`Point(1, 2)`, `Shapes.area(3)`) could not be jumped
to at all, because `Checker.typeOfCall` resolves a call's callee through `referenceOf` without
ever calling `typeOf` on it, so the callee has no entry in `expression_types` for
`expressionAt` (hover's lookup, reused here) to find — only the call as a whole does.
Still missing, matching this file's other conservative capture-analysis entries: a
declaration, assignment, or type annotation written inside a lambda's own block body is
unreachable, since the statement-tree walkers descend into every block a statement owns but
not into an expression looking for one.

Find references is implemented, the same three facts read the other way: given a
declaration's site (found by reusing `definitionAt` itself — the cursor can sit on a read, a
write, or the declaration), one ordinary recursive descent through every file's whole
statement and expression tree collects every site whose own resolved target matches it. Unlike
`definitionAt`'s narrow, stop-at-the-first-match walkers, this one visits every sub-expression
of every statement (loop conditions, call arguments, list/dict literals, binary and logical
operands, and so on) and every written type annotation, since finding every reference needs
full coverage rather than a point query — and, as a side effect, it reaches into a lambda's own
block body, the one place `definitionAt` still cannot (the gap above). `textDocument/references`
respects `context.includeDeclaration`, defaulted to false rather than required, since an absent
or malformed one is a missing preference, not a malformed request. A reference to a
prelude-declared symbol (`RuntimeError` and the rest) is not found at all, for the same reason
`onDefinition` already declines it: a prelude declaration has no file on disk to report a
location in. Verified end to end over JSON-RPC, including a two-file project, both with and
without `includeDeclaration`.

Rename is implemented, directly on find references: the declaration plus every site find
references collects, each site's span replaced by the new name and grouped into one
`TextEdit` array per file as a standard LSP `WorkspaceEdit` (`std.json.ArrayHashMap`, the
first dynamic-keyed JSON object this server writes rather than a fixed struct). A new
`isValidIdentifier` checks the proposed name against the lexer's own identifier grammar
(Unicode's XID classes, with a single trailing `?` or `!` allowed) before touching anything,
so a rename cannot write a name the parser would immediately reject. `textDocument/rename`
returns a JSON-RPC error (`-32602`, reusing "invalid params" since LSP defines no
rename-specific code) rather than an edit for an invalid name, a closed document, a project
that fails to check, a position that resolves to nothing, or a prelude-declared symbol — the
last for the same reason go to definition and find references already decline one. No
`prepareRename`: a client that calls it first (VS Code does) falls back to its own idea of the
word under the cursor, and the resolution above still runs against whatever position that
implies, so it fails safely rather than renaming the wrong thing. Verified end to end over
JSON-RPC: a cross-file rename correctly grouped into two files' edits, and an invalid new name
correctly rejected rather than crashing or silently corrupting the source.

Completion is implemented, the last piece of the LSP's second phase and the one piece that
was never going to be "more of the same." An in-progress member access, `foo.` or `foo.par`,
does not merely lack a type the checker never computed — it fails to *parse* at all:
`finishMember` (`Parser.zig`) reports a diagnostic and unwinds to the nearest statement
boundary, discarding everything before the dot along with it. Building a real error-tolerant
grammar to keep a partial node around would touch `Parser.zig`'s recovery for every caller
(`check`, `run`, `format`, and every conformance and diagnostic golden file), to serve one
editor feature — so a completion request instead patches a throwaway copy of the buffer:
`foo.` becomes `foo.placeholder()`, a fixed, always-valid synthetic call, and
`appendUnclosedBrackets` closes whatever `(`, `[`, or `{` the surrounding statement (very often
still unclosed — `print(foo.` mid-call is the ordinary case) had left open. A bare
`placeholder` with no call very nearly worked and was the first thing tried: it still gets
discarded as an unused-result statement (section 5.2) when the dot sits alone on its own line,
and separately, a dot's own newline-suppression (`Lexer.zig`'s continuation rule, for fluent
chains) can swallow a real, unrelated statement immediately following on the next line into
the same broken expression. Wrapping the placeholder in a call fixes both: `)` both makes it a
call and ends the newline suppression. Scoped to a value's own member access (fields,
properties, methods, walking base classes and adopted traits) — a type-qualified base's own
completions (10.4) turned out to need a second, separate analysis pass and were cut from this
slice; see the rough edge below for the specific reason the same trick can't reach them.

Brace style (3.4) is now a per-project choice rather than a single hardcoded rule: a project
picks Stroustrup (the default) or Allman in `emerald.toml`'s new `brace_style` key — the
manifest's first real key, ahead of the rest of it (24), which stays a roadmap item. This
reverses the original "Stroustrup is the only legal spelling anywhere" decision (see the
decision table addition in `rewrite-context.md` section 22 for why). The grammar itself
accepts both styles unconditionally and everywhere a block opens (`if`/`while`/`for`,
`try`/`catch`/`finally`, `case` and its arms, struct/class/trait/enum bodies, functions,
constructors, and both a read-only and a `get`/`set` property) — brace placement is
whitespace, so the parser was made to treat it that way, via `Parser.zig`'s new
`atLeftBrace`/`skipToLeftBrace` (peeking, and optionally skipping, past a newline wherever the
grammar already checked for a `{`). The formatter is the only place the choice matters:
`Project.zig`'s `readBraceStyle` reads `emerald.toml` next to `main.em` (a hand-rolled
single-key reader, not a TOML library, matching the manifest's still-minimal scope) and
`Formatter.zig`'s `printBraceOpen` is the one place every block-opening call site now goes
through, so `emerald format`/format-on-save always normalize to the project's chosen style
regardless of which one a file was actually written in. A lone file outside any project (no
`main.em` to root a manifest search from) always defaults to Stroustrup.

`Directory.delete_recursive(path)` is implemented, closing half of the "streaming/binary I/O
and recursive directory delete" backlog bullet (the other half is unchanged and still needs
its own design pass — see "Next step"). It mirrors `Directory.create`'s idempotence in the
other direction: `create` treats an already-existing path as success, `delete_recursive`
treats an already-gone one the same way, both via `std.Io.Dir`'s own native support
(`createDirPath`/`deleteTree`) rather than hand-rolled recursion. `conformance/run/file-directory-path.em`'s
teardown now uses it (called twice, proving the idempotence) in place of the six manual
`File.delete`/`Directory.delete` calls an empty-only `Directory.delete` used to require.

## Next step

The LSP's second phase is complete: hover, go to definition, find references, rename, and
completion. A 2026-09-20 roadmap review had triaged prior "what's next" suggestions from both
agents against the binary at the time; everything from that review is now either closed or
named-but-unordered below, and nothing is yet authorized as the next thing to build. Closed and
no longer live from that review: per-family runnable examples, `!`/optional/callback/raise
labeling, conformance-programs-as-executable-examples, the filesystem design, the five
maintainability findings (retired in `6a6a718`), the program entry point, and the opportunistic
trait `is` analysis (streaming I/O and the bounded implementation limits below were bundled
with it but were not done, and were not promoted to a named next step; nothing currently
motivates either).

Named but unordered: `emerald explain`/diagnostic polish; a custom equality/hashing design
pass, the natural sibling to `Textual`/`Ordered`; streaming/binary file I/O (still needs its
own design pass — recursive directory deletion, the other half of this bullet, no longer
does; it shipped, see below); expanding `emerald.toml`
beyond `brace_style` with more formatting-convention keys and a configurable warning level
for formatting-adjacent diagnostics — explicitly not ready to start (user said so), and
needs its own design pass first: whether the manifest grows into per-rule severity (an
ESLint/Rubocop shape) or stays a small, closed set of style axes (a rustfmt/gofmt shape) is
still open; see roadmap item 24 in `rewrite-context.md`. The big deferred-features
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
- Go to definition does not reach a declaration, assignment, or type annotation written inside
  a lambda's own block body — the statement-tree walkers behind it descend into every block a
  *statement* owns, not into an *expression* looking for one. Find references does not have
  this gap (it visits every expression, lambda bodies included), so the two can disagree on a
  lambda-local symbol: references finds it, definition-from-inside-the-lambda cannot.
- Find references does not find a reference to a prelude-declared symbol (`RuntimeError` and
  the rest), matching go to definition's own reason for declining one: a prelude declaration
  has no file on disk to report a location in. Rename declines the same symbols for the same
  reason.
- Rename has no `prepareRename`, so a client with no fallback of its own (most have one) may
  offer to rename a position that then turns out not to be renameable.
- Completion answers only a value's own member access (fields, properties, methods). A
  type-qualified base's own completions (10.4's `Vector2.origin`) are not answered:
  `Resolver.zig`'s `qualify` validates a type-qualified reference eagerly, so patching in an
  unknown placeholder member fails the *whole* analysis (a resolver diagnostic, not a checker
  one) rather than leaving one expression untyped the way an unknown instance member does.
  Namespace-level completion (`Shapes.` suggesting what the namespace declares) and a bare
  identifier with no preceding dot are also not answered.
- `emerald.toml`'s `brace_style` is read by a hand-rolled single-key line scanner, not a real
  TOML parser (24 is still unimplemented beyond this one key): a missing file, an unknown key,
  a malformed line, or a value other than `"allman"` all silently fall back to the
  `stroustrup` default rather than producing a diagnostic. Fine for one key with two valid
  values; revisit once the manifest holds enough that a silent typo becomes worth catching.

## Validation and repository state

The latest completed slices, including the program entry point, the ledger shakedown, the
trait-aware impossible-type-test warning, LSP hover, the Windows path/lexer fix, go to
definition, find references, rename, completion, the per-project brace style, and recursive
directory deletion, passed `bash tools/check-toolchain.sh`, `zig build test` in Debug and
ReleaseSafe (383/383 tests), `bash tools/check-doc-examples.sh` after `zig build`, and
`git diff --check` with pinned Zig 0.16.0. Go to definition, find references, rename, and
completion were each also checked end
to end against the real LSP server over JSON-RPC (single-file member access and constructor
calls; a two-file project crossing into a sibling file, both with and without
`includeDeclaration`; a cross-file rename's grouped edits; an invalid new name's rejection;
completion on its own line, mid-call with an unclosed paren, and the documented
type-qualified-base and no-dot cases correctly returning nothing), not just their Zig unit
tests — which is how both go to definition's constructor-call gap and completion's own
bare-placeholder failure mode were actually found. Brace style was checked the same way: the
CLI (`emerald format` normalizing a hand-written mix of both styles to whichever
`emerald.toml` asked for, in both directions, and idempotently on a second pass) and the LSP
(`textDocument/formatting` over real JSON-RPC against a real two-file project with an
`emerald.toml`, and separately against a lone file outside any project, confirming the
Stroustrup default). Recursive directory deletion was checked the same way, beyond its Zig
unit test: a manual `emerald run` against a real nested directory tree, printing
`Directory.exists?` before and after, confirming the deletion was idempotent on a second
call, and independently confirming with `ls` on the host filesystem that the whole tree —
not just the top-level path — was actually gone. The Windows path/lexer fix's
Windows-specific half could not be verified locally and was confirmed by CI instead. The
working tree was clean after commit `0dd083b` (`Make brace style a per-project choice
instead of hardcoded Stroustrup`) before this pass.

When a change affects behavior, prefer end-to-end conformance coverage. Before handoff, run
the checks appropriate to the change and update this file's status rather than adding a
session diary.
