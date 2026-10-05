# REPL: design and implementation plan

Status: accepted, 2026-09-30. The user accepted the eight recommendations below by planning to start the work; Codex begins after the bug-fix batch is merged. `emerald repl` (18.4) was
built quickly, and it now does things a student never asked for. This plan replaces its core
while keeping its surface: the prompt, multiline entry, echoing a bare expression's value, and
`:help`, `:reset`, and `:quit`.

Implementation: all four slices complete on `codex/repl`; final review and merge pending.

The executor makes the remaining judgement calls within a slice and records each one under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## What was wrong before this milestone

This section records the replay implementation replaced by slices 1–3, not the current
`src/Repl.zig`. The append demonstrations need no setup file: File.append now creates it.

The REPL keeps one ever-growing source text and, on every entry, lexes, parses, resolves,
checks, and runs **the whole session again** from the start (`src/Repl.zig`). To hide that, it
discards the output it already showed and replays recorded `input` lines. Its header comment
justifies this: "Every language feature that exists today is observable only through
`print`/`input` (no clock, filesystem, network, or randomness)". That stopped being true with
files, HTTP, dates, `Random`, the clock, and tasks. So today:

```text
> File.append("log.txt", "x")
> print(1)
1
> print(2)
2
```

leaves `log.txt` holding `xxx`: the append ran three times. The same happens to an `Http.post`,
a `Random` result (a different number every entry), `Date.today()`, `Stopwatch`, and every task.
Each entry also gets slower as the session grows, since everything before it runs again.

It also leaves out what a student most wants to see. A bare method or function call prints
nothing, though it printed a property:

```text
> "abc".upper()
> 2.0.square_root()
> [1, 2].count
2
```

The call's result is thrown away because the REPL echoes only a statement the parser would reject
as "this result is never used", and a call may discard its result. And an error in a later entry
is reported at its position in the whole session (`<repl>:2:1` for a one-line entry), because the
session is one growing text.

Two smaller problems:

- It decides whether an entry is unfinished (so it should ask for another line) and whether it is
  a bare expression (so its value should be printed) by comparing error-message text
  (`classifyEntry`: `"this block is never closed"`, `"this result is never used"`). Rewording a
  message silently breaks the REPL.
- "An invalid entry does not partially mutate the session" (18.4) is only true because of the
  replay. With real side effects, no REPL can undo an `Http.post`; the rule needs rewording.

## What a student should see

```text
> const name = "Ada"
> var count = 0
> count += 1
> count
1
> "Ada".upper()
"ADA"
> 2.0.square_root()
1.4142135623730951
> File.append("log.txt", "x")
> print(Random(1).next(1..6) == Random(1).next(1..6))
true
> func greet(who: String): String {
.     return "Hello, #{who}!"
. }
> greet(name)
"Hello, Ada!"
> count = "many"
repl:1:9: this is String, but `count` holds Int
> const name = "Grace"
repl:1:7: `name` is already declared
  Declare a different name, or type :reset to start over.
```

The append runs once. Each entry runs once, when it is entered, and the output above is the
whole output. (Diagnostics are shortened here: each also quotes its line with a caret, as in a
file. `"Hello, Ada!"` is quoted because of decision 4; today the REPL echoes a string unquoted.)

## Principles

1. **Every entry runs exactly once.** Nothing entered earlier runs again, so side effects happen
   once, `Random` and the clock behave as in a program, and executing an entry costs the same
   late in a session as early. Full-session analysis grows with the kept program.
2. **The same language as a file.** A session checks as one program would: the same binding
   rules, types, and diagnostics. The REPL adds no rules of its own beyond what an interactive
   session forces (decision 2).
3. **Structure, not message text.** Whether an entry is unfinished, and whether it is a bare
   expression, comes from the parser's own results, never from matching a diagnostic's words.
4. **Honest about what can't be undone.** An entry that fails to check changes nothing. An entry
   that fails while running cannot take back what it already did, so the REPL keeps those effects
   and says so in its help; it does not pretend otherwise.

## Verified constraints (checked against source, 2026-09-30)

- **The pipeline is single-shot** (`emerald.zig`: "Resolution, checking and execution each see
  the whole project at once"), and `Resolver.checkModuleFile` lets only the entry file hold
  executable top-level statements. The REPL today avoids both by being one growing entry file.
- **Checker results are keyed by syntax-tree node** (`expression_types`, `json_encodes`, method
  and operator selections, resolver facts). Checking the same nodes again yields the same keys,
  so if earlier entries are parsed **once** and their nodes are kept, the whole session can be
  re-checked cheaply each time and every earlier node still has its facts. Re-*parsing* them, as
  today, is what makes old facts useless.
- **Runtime values do not point at checker types.** A struct value's type is the interpreter's
  `Value.StructType`, found by key string in `Interpreter.structs`, not the checker's
  `Type.User`. The interpreter's own tables (`functions`, `structs`, `constructors`,
  `trait_infos`, `struct_infos`, `type_setups`) use both source names and synthesized keys
  allocated by the resolver. The session must retain the original syntax trees and own any
  synthesized keys stored in runtime tables or closures; retaining trees alone does not keep
  those keys alive after an old analysis is freed (verified by the slice 2 correction).
- **The interpreter holds pointers to one analysis** (`signatures`, `method_calls`,
  `operator_calls`, `json_encodes`, `prelude_reached`, and so on). A new entry's analysis replaces
  them all at once. Correction from slice 2 review: a failed entry can assign code into an
  earlier binding, so its analysis must remain alive. Calls into that code select the failed
  entry's retained analysis, and calls into kept code select the current analysis, restoring
  the caller's view afterward.
- **Spans are offsets into one `Source`.** An append-only session text keeps every earlier span
  valid, as long as a new entry is lexed and parsed from its own starting offset. Whether
  `Lexer.tokenize` and `Parser.parse` can start at an offset of an existing `Source` must be
  checked in slice 1; `Parser.parse` takes a whole `Source` and its tokens today.
- **The concurrency milestone** changed the interpreter's state into a `TaskState` behind
  `Scheduler.zig`, with a scheduler-owned standard-input reader. The REPL reads its own lines from
  standard input too, so the two must share one reader (slice 3).

## Proposed design

A session is one append-only source text and a list of already-parsed top-level statements. For
each new entry:

1. Append the entry's text to the session source, then lex and parse **only the new part**,
   starting at its offset. Previous statements are kept as they are.
2. If the parser says the entry is unfinished (an open block, call, list, string, or comment at
   the end), ask for another line. If it has a syntax error, report it and exclude its statements.
   Submitted text stays in the append-only source, even when its entry is dropped.
3. Build the session program from all kept statements plus the new ones, and resolve and check it
   as a whole. Earlier nodes are the same objects, so their facts come out the same.
4. If checking reports an error in the new statements, report it, exclude those statements,
   and keep the previous analysis. Nothing has run; its source offsets are not reused.
5. Otherwise give the interpreter the new analysis, let it register any new declarations, and run
   **only the new statements**, in the module scope that persists from earlier entries.
6. If a new top-level statement is an expression, a call included, and its type is not
   `Nothing`, print its value as `print` would, except that a `String` is shown quoted, so
   `"Ada"` and `Ada` look different (decisions 4 and 6). A declaration, an assignment, and a call that
   returns nothing (`print`, `append`, `File.write`) print nothing extra.
7. Report a diagnostic's position within the entry (`repl:1:9`), not within the session text.

The interpreter, its heap, its module scope, open files, the HTTP client, the random engine, and
the scheduler all live for the whole session and end at `:reset` or exit.

## Decisions

All eight were accepted as recommended on 2026-09-30. The alternatives are kept for the record.

1. **Keep one persistent interpreter and re-check the session on each entry (recommended),** as
   above. Re-checking is cheap (checking has no side effects, and the prelude is checked lazily),
   and it keeps "the same language as a file" for free. Alternatives: keep replaying but suppress
   side effects during replay, which cannot work in general (a clock, a random number, and a
   network reply cannot be replayed faithfully); or make the checker itself incremental, which is
   the right long-term structure but a much larger change than the REPL needs.
2. **An entry that raises while running is dropped (recommended).** Its declarations are removed,
   as if it had never been entered, so a later entry cannot see a name that was declared after the
   error and never assigned. What it already did stays done: a changed `var`, output, a file
   written, a request sent. The error is shown as in a program. Alternative: keep the entry, and
   with it any declarations before the error, which is what Python does; that would let a later
   entry read a name the checker believes is assigned but the run never reached.
3. **Redeclaring a name is an error, as in a file (recommended),** with a REPL hint: "Declare a
   different name, or type :reset to start over." Alternative: let a new declaration replace the
   old one, which most scripting REPLs allow; in a typed language it leaves earlier functions
   checked against a type that no longer exists.
4. **A bare `String` value is echoed quoted (recommended),** so `"Ada"` is visibly text, the way
   a list already shows its strings quoted. `print` is unchanged. Alternative: echo exactly as
   `print` does.
5. **Unfinished-entry and bare-expression detection come from the parser (recommended):** the
   parser reports "incomplete at end of input" as its own flag, and marks a statement that is a
   bare expression. Alternative: keep matching message text, which breaks whenever a message is
   reworded, as the diagnostic work regularly does.
6. **Echo every expression statement's value, calls included, unless it is `Nothing`
   (recommended).** `"abc".upper()` shows `"ABC"`; `print("hi")` shows `hi` once, not also its
   result. The checker's type for the statement decides it, not the parser, since only the type
   says whether a call returns something. Alternative: echo only non-call expressions, as today,
   which hides exactly the results a student is exploring.
7. **Positions are within the entry (recommended),** `repl:1:9` for the first line of what was
   just typed, so a message points at what the student can see. Alternative: session-wide line
   numbers, which grow with the session and point at text no longer on screen.
8. **No new commands in this plan (recommended).** Keep `:help`, `:reset`, and `:quit`; update
   `:help`'s text to say what an interrupted entry keeps. Candidates for later: `:type expression`,
   `:load file.em`. Line editing and history (arrow keys, recalling an earlier line) is the most
   visible improvement a student would notice, but on macOS and Linux it needs raw terminal input,
   the same machinery a full-screen terminal library needs (parked in 24); on Windows the console
   already provides it. It is a separate plan.

## Slices

Each slice ends with the full validation below passing, and one commit or a short series of
commits.

### Slice 1: Parsing an entry on its own

- Lex and parse a new entry as the tail of an existing `Source`, from an offset, so its spans are
  offsets into the session text and earlier nodes are untouched.
- The parser reports "incomplete at end of input" as a result flag, set only by an unclosed
  block, call, list, lambda, `case`, string, or block comment at the very end.
- The parser marks a top-level statement that is a bare expression, a call included (today the
  REPL keys on the "this result is never used" error and so misses calls); the REPL decides
  whether to echo from the checker's type for it (decision 6), and a file still reports the error
  for a non-call.
- Replace `classifyEntry`'s message matching with these, and keep its unit tests passing.
- Settled while building:
  - `Lexer.tokenizeFrom` starts at a committed entry boundary, where delimiter
    state is clean; it preserves global spans without re-lexing an earlier
    statement. The session will only call it after an entry's terminating
    newline.
  - The lexer owns incomplete block-comment and multiline-string state; the
    parser owns incomplete delimiter/block/case/lambda state. Both expose
    flags, so `Repl.classifyEntry` never examines diagnostic wording.
  - An EOF diagnostic counts as parser-incomplete only while a delimiter is
    structurally open. Thus `var value =` remains an immediate syntax error,
    while `print(` or an open block asks for another line.
  - `Ast.Statement.interactive_expression` is set only by `parseEntry`, for
    all top-level expression statements including calls. File parsing retains
    section 5.2's unused non-call diagnostic.

### Slice 2: An interpreter that lasts a session

- Split interpreter setup from running: build it once, then, per entry, install a new analysis,
  register the declarations that are new, and run statements from a given index in the persisting
  module scope.
- Removing a dropped entry's declarations (decision 2): the module scope, and the interpreter's
  tables for any functions or types it declared.
- Unit tests in Zig that drive the interpreter through several entries directly, including a
  struct value and a closure created in one entry and used in later ones, a type declared later
  than a value that uses an earlier type, and a raising entry.
- Settled while building:
  - `Interpreter.Session` is a separate persistent path; the one-shot
    `Interpreter.run` path remains intact for `run`, `test`, and embedding
    callers.  This keeps the REPL lifetime change contained while both paths
    continue to share execution semantics.
  - `SessionSyntax` owns source snapshots and entries parsed exactly once with
    `tokenizeFrom`/`parseEntry`. `analyzeSession` builds each program from those
    same statement nodes plus the new entry. Successful entries use the current
    resolver/checker analysis; obsolete successful analyses are freed after replacement.
    Failed entries retain their analyses for code that escapes through an assignment.
    Runtime tables and callable values own synthesized resolver keys in the
    session arena, so freeing previous analyses cannot leave dangling names.
  - A session always uses `Scheduler.SharedAllocator`, even before `Tasks` is
    named.  A later entry may introduce tasks, and changing allocation domains
    underneath existing heap values would be unsound.
  - A failed entry removes only names and runtime declaration tables introduced
    by that entry.  Its preceding assignments and external effects remain, as
    decision 2 requires.  Type descriptors and other arena allocations may
    remain until `:reset`; their names are not resolvable from later entries.
  - Further slice 2 review reproduced a missing-facts panic when a failed entry
    assigned a lambda into an earlier `var`. Session analyses now have stable,
    heap-owned addresses and transfer ownership through `ownedSessionAnalysis`.
    The session retains each failed analysis until teardown, together with a
    snapshot of runtime declaration tables: an escaped instance needs its methods
    and constructors even after their names are removed or reused in a later entry.
  - Closures (including nested function closures), runtime struct descriptors,
    and callables carry their declaring entry's source offset. Named declarations
    recover that origin from their kept name span. Each call selects the failed
    origin's view, or the current view for kept code, then restores its caller's
    view on success or failure. Field/parameter defaults and constructors follow
    the same rule. The scheduler restores the view with the task when returning
    the baton, so a yield cannot leave another task's checker facts installed.
    Prelude bodies keep their caller's analysis because they are checked lazily:
    a helper reached only from failed-entry code may have no facts in the current
    analysis. A regression verifies this with `Console.green` after its only
    reaching entry is dropped.
  - `dropLast` drops statements only, never source text. Later entries start after
    all prior text, including failures, so span-keyed nested-function facts cannot
    collide. Testing-allocator regressions cover the requested `20` result,
    escaped nested functions calling kept code, a later nested function at the
    formerly reused offset, yields across task views, and a trait-backed escaped
    instance/captured method constructing its old type after that name is reused.
  - Correction to `b9e5804`: its test reparsed earlier entries, violating the
    node-identity invariant and panicking in `closureCallable`. Its claimed
    validation was incorrect: the executor printed only command output and
    failed to inspect returned process-session IDs and final exit statuses.
    The corrected tests free each obsolete analysis immediately and exercise
    earlier lambdas, captured private functions, captured methods, and struct
    construction through earlier values under `std.testing.allocator`.

### Slice 3: The new REPL

- Rewrite `Repl.zig` on slices 1 and 2: the session source, the kept statements, the persistent
  interpreter, the echo, `:reset` (a new interpreter and session), and the updated `:help`.
- Share the scheduler's standard-input reader between the REPL's own prompt and the program's
  `input`, so neither loses a line to the other.
- Diagnostics positioned within the entry (decision 7): map a session offset to the entry's own
  line and column when rendering.
- A transcript test category, `conformance/repl/`: each case is a `.input` file of typed lines and
  an `.expected` transcript. Cover every example in "What a student should see", a side effect
  that must happen once (a file append, checked after the session), `Random` and `Date.today()`
  across entries, a multiline function, each unfinished-input form, a check error and a runtime
  error (and what each keeps), redeclaration, `:reset`, `Tasks.run` in an entry, echoes of calls,
  properties, and nothing-returning calls, and an error position in a late entry.
- Execution work (QA A5 correction, 2026-10-04): assert equal interpreter steps at entries
  5 and 500, and origin comparisons bounded by lookups times the bit length of the origin
  count. Wall-clock timings remain a manual benchmark, never a CI assertion. Different
  retained heaps naturally give different collector work; do not assert equality there.
  Analysis is also measured, not asserted in CI.
- In ReleaseSafe, record median analysis times at entries 5, 100, 500, and 1000, including
  resolve/check breakdown and whether the prelude is redone. Entry 500 must be under 100 ms
  on the development machine; otherwise stop and report it.
- Settled while building:
  - The two review probes supplied against `94705cb` are added as
    testing-allocator regressions: an escaped failed-entry lambda prints `20`,
    and failed-entry code calls back into a later lambda/struct method and
    prints `1070 20`.
  - `Session.originOf` now uses an upper-bound binary search over the
    append-only origin offsets. A boundary test covers empty indexes, gaps
    from entries rejected before installation, exclusive ends, and other files.
  - Before wiring the new command loop, a temporary ReleaseSafe timing probe
    exercised the persistent-session path with 500 entries, each declaring
    `const job_N = { => 1 }`. It timed append/analysis/install separately from
    running only the new statement, using the page allocator and monotonic
    clock on Linux x86_64, Zig 0.16.0. Three confirming runs had total entry-5
    times of 5.858, 4.153, and 4.196 ms; entry-500 times were 22.071, 23.143,
    and 21.417 ms. Medians: **4.196 ms versus 22.071 ms (5.26x)**.
    Execution alone was 0.004–0.007 ms; analysis/install dominated the growth.
    The initial build's run measured 5.910 versus 36.881 ms. The temporary
    printing probe was removed after measurement, not added to normal CI.
  - **Plan error corrected with user approval:** full-session rechecking (decision 1)
    is not constant-cost as statements accumulate. A binary origin lookup
    cannot make entry 500's total latency equal entry 5's, while an incremental
    checker is explicitly out of scope. The user approved replacing the total
    latency assertion with flat execution, measured analysis, and a local
    100 ms analysis budget at entry 500. This corrects the original criterion
    rather than changing decision 1 or introducing an incremental checker.
  - The command loop owns a persistent interpreter and syntax store on one
    reserved stack, keeping normal recursion limits. Each new analysis is
    installed before only its new statements run. Initial construction borrows
    an analysis and transfers ownership on success; later installation owns it
    immediately, including on allocation failure.
  - Echo uses the original expression and its checked type, never a generated
    `print` call. `Nothing`-typed calls execute without an extra echo; optional
    results that are `nothing` do echo `nothing`. Strings use quoted value
    display; other values use ordinary `print`/`Textual` display.
  - One scheduler-owned input reader serves both prompts and program input.
    The command loop owns it across `:reset`, while each interpreter borrows it.
    CLI input uses the process-owned reader; transcript tests use a finite
    fixed reader that is joined and freed under the testing allocator.
  - Diagnostic spans, trace frames, and related failures are each mapped to
    their originating entry, including calls from escaped failed-entry code.
    A resolver-failure callback renders diagnostics before its temporary arena
    is freed. Earlier user warnings are not printed on every recheck. Only
    top-level redeclarations receive the REPL reset hint.
  - Two omissions surfaced while wiring the real command loop: type bodies
    did not set the interactive incomplete flag, and `SessionSyntax` did not
    keep `Program.using`. Open struct/class/trait/enum bodies now request
    continuation without changing file diagnostics. File-local `using` nodes
    are kept alongside statements and dropped together after a failed entry.
    Lexical/parse failures also keep their text/offsets, without contributing
    statements or aliases. Completion detection parses temporary drafts; only
    the final stored trees are used for all later analyses and execution.
  - `conformance/repl/` uses `.input`/`.expected` transcripts, checked 50 times
    consecutively on every platform gate. Goldens were read by hand. Prompt
    spaces are intentional, so only these expectations opt out of Git's
    trailing-space warning. A testing-allocator file test repeats 50 sessions
    and checks the actual append after teardown; output alone cannot prove it.
  - The CI execution assertion alternates 31 paired samples at entries 5/500,
    with three executions of a 512-iteration callable-creation loop per sample.
    It excludes analysis and uses medians with five median absolute deviations
    plus a 100 microsecond scheduling/clock floor per batch, chosen before
    validation. Both prefixes have the real origin index and runtime bindings;
    setup builds their checked programs once rather than timing 500 analyses.
  - Analysis profiling is reproducible with
    `zig build repl-benchmark -j1 -Doptimize=ReleaseSafe`. It measures nine
    warmed samples at each prefix, not a CI timing assertion. Each entry is
    `const job_N = { => 1 }`; total analysis includes setup and reserved-thread
    overhead, but not candidate parsing, installation, or old-analysis release.
    The final ReleaseSafe run on Linux x86_64, Zig 0.16.0, measured:

    | Entry | Analysis median (ms) | Resolve (ms) | Check (ms) |
    | --- | --- | --- | --- |
    | 5 | 2.347 | 1.128 | 0.770 |
    | 100 | 3.478 | 1.162 | 1.836 |
    | 500 | 13.240 | 1.568 | 11.107 |
    | 1000 | 34.156 | 2.064 | 31.518 |

    Entry 500 is below the approved 100 ms local budget. Checking accounts for
    roughly 84% there; resolving grows much less. The prelude AST is compiled
    once and is never lexed/parsed per entry, but each fresh resolver/checker
    rebuilds its names, type/trait metadata, and signatures. Prelude bodies
    reached by kept user code are checked again; unreached bodies remain lazy.
    No incremental checker or cached prelude analysis was introduced.
  - Final local validation passed with pinned Zig 0.16.0 and `-j1`: Debug and
    ReleaseSafe suites (546 tests each), native build, documentation examples,
    changed-Zig formatting, whitespace checks, and Windows x86_64/macOS
    aarch64 cross-builds. All nine transcripts also matched 50/50 runs each
    through the built CLI (450 processes, no retries).

### Slice 4: Documentation and integration

- `docs/language` and the rewrite-context 18.4 text: every entry runs once; what a failing entry
  keeps; the echo; redeclaration. Remove the replay's justification.
- Section 22 gets a row for replay versus a persistent session, recording why replay was
  retired.
- The handoff and journal; the 0.7.0 release-notes list (the REPL no longer repeats side
  effects, and a bare `String` echoes quoted).
- Settled while building:
  - Merged `origin/main` into `codex/repl` before integration, without rebasing
    or rewriting history. The seven commits merged without conflicts; main's
    File.append dispatch change and section 15.3 text remain intact, alongside
    the REPL session work. Its editor-intelligence, board-target,
    batteries-included, header-block, and release notes are preserved.
  - Added a focused `docs/language/repl.md` guide and linked it from the guide
    index. Normative changes in the rewrite context are confined to 18.4 and
    section 22; the plan's replay description is explicitly historical.
  - The append example starts in a fresh directory, without a setup file.
    The 50-session file-effect regression also uses a missing file each time,
    removing it only after verifying `x`. No existing transcript or expected
    output changed; main's new `file-append-creates` case remains as merged.
  - The handoff's completed slice narrative is condensed, with history kept
    in the journal. New REPL release notes sit beside main's existing notes,
    without duplicating the File.append, CRLF, User-Agent, Console, or tasks entries.
  - Post-merge validation passed with pinned Zig 0.16.0 and `-j1`: Debug and
    ReleaseSafe suites (546 tests each), native build, the doc-example check
    (24 executed examples, 134 linked conformance files), formatting/whitespace,
    and Windows x86_64/macOS aarch64 cross-builds outside `zig-out`.
    The nine existing transcripts each matched 50 actual CLI runs (450 processes,
    no retries) as well as 50 runs in each test gate. All three new guide
    transcripts were verified against the built binary, including the fresh
    file holding exactly `x` and the shortened error's `repl:4:5` location.

## Validation

Every slice must pass, on the pinned Zig 0.16.0 with `-j1`:

- Debug and ReleaseSafe `zig build test -j1`;
- `zig build -j1`;
- `bash tools/check-doc-examples.sh`;
- `zig fmt --check` on changed Zig files;
- `git diff --check`;
- Windows and macOS cross-builds with `--prefix` outside `zig-out`.

Slice 3 also runs every transcript case 50 times in a row, since it runs tasks and reads standard
input; a case whose transcript ever differs is a bug, not a flake.

## Out of scope

- Line editing, history, and tab completion (decision 8).
- New commands (`:type`, `:load`, `:save`).
- Undoing an entry's outside effects, which no REPL can do.
- An incremental checker; the session is re-checked in full, which this plan measures.
