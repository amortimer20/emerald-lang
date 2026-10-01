# REPL: design and implementation plan

Status: accepted, 2026-09-30. The user accepted the eight recommendations below by planning to start the work; Codex begins after the bug-fix batch is merged. `emerald repl` (18.4) was
built quickly, and it now does things a student never asked for. This plan replaces its core
while keeping its surface: the prompt, multiline entry, echoing a bare expression's value, and
`:help`, `:reset`, and `:quit`.

The executor makes the remaining judgement calls within a slice and records each one under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## What is wrong now

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
   once, `Random` and the clock behave as in a program, and an entry costs the same late in a
   session as early.
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
  `trait_infos`, `struct_infos`, `type_setups`) are keyed by strings that point into the syntax
  tree. So values from earlier entries stay valid across a re-check, provided the syntax tree they
  point into is kept.
- **The interpreter holds pointers to one analysis** (`signatures`, `method_calls`,
  `operator_calls`, `json_encodes`, `prelude_reached`, and so on). A new entry's analysis replaces
  them all at once.
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
   the end), ask for another line. If it has a syntax error, report it and drop the new text.
3. Build the session program from all kept statements plus the new ones, and resolve and check it
   as a whole. Earlier nodes are the same objects, so their facts come out the same.
4. If checking reports an error in the new statements, report it, drop the new text and
   statements, and keep the previous analysis. Nothing has run.
5. Otherwise give the interpreter the new analysis, let it register any new declarations, and run
   **only the new statements**, in the module scope that persists from earlier entries.
6. If a new top-level statement is an expression, a call included, and its type is not
   `Nothing`, print its value as `print` would, except that a `String` is shown quoted, so
   `"Ada"` and `Ada` look different (decision 6). A declaration, an assignment, and a call that
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
- Settled while building: (record here)

### Slice 2: An interpreter that lasts a session

- Split interpreter setup from running: build it once, then, per entry, install a new analysis,
  register the declarations that are new, and run statements from a given index in the persisting
  module scope.
- Removing a dropped entry's declarations (decision 2): the module scope, and the interpreter's
  tables for any functions or types it declared.
- Unit tests in Zig that drive the interpreter through several entries directly, including a
  struct value and a closure created in one entry and used in later ones, a type declared later
  than a value that uses an earlier type, and a raising entry.
- Settled while building: (record here)

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
- A timing check: entry 500 of a session is no slower than entry 5, within noise.
- Settled while building: (record here)

### Slice 4: Documentation and integration

- `docs/language` and the rewrite-context 18.4 text: every entry runs once; what a failing entry
  keeps; the echo; redeclaration. Remove the replay's justification.
- Section 22 gets a row for replay versus a persistent session, recording why replay was
  retired.
- The handoff and journal; the 0.7.0 release-notes list (the REPL no longer repeats side
  effects, and a bare `String` echoes quoted).
- Settled while building: (record here)

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
