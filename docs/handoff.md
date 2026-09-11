# Current handoff

Updated: 2026-09-11. Prepared by Claude after fixing an external review of the functions
slice.

## Current milestone

Slices 1 through 7 of section 20 are complete. The whole frontend pipeline of section 19.2
exists: source manager, lexer, parser, name resolver, type checker, interpreter.

Functions work: declarations, calls, returns, recursion, hoisting, return-type inference,
and stack traces on runtime errors. Every expression has a static type before execution and
definite assignment is proved through control flow. What remains at runtime is only what
cannot be known statically: integer overflow, division by zero, and exceeding the
recursion limit.

## Completed foundation

- The .NET prototype is archived under `legacy/dotnet-v0/`, tagged `dotnet-v0-final`.
- [rewrite-context.md](rewrite-context.md) is the canonical language and architecture
  baseline. The implementation host is Zig.
- Zig `0.16.0` is pinned through [mise.toml](../mise.toml) and
  [toolchain/zig-version.txt](../toolchain/zig-version.txt), verified by
  [tools/check-toolchain.sh](../tools/check-toolchain.sh).
- Shared agent instructions are committed in `AGENTS.md` and `CLAUDE.md` (`f3c38cb`).

## Pre-implementation decision pass

The user asked for a judgment call on the remaining open design questions, prioritizing
beginner friendliness, sound design, and expressive syntax. Seven decisions were settled
and recorded in the rewrite context, each in its normative section plus a summary table in
section 22 under "Pre-implementation decision pass":

- `Int` is 64-bit signed with checked overflow; `Float` is IEEE-754 binary64 (4.2, 5.3).
- The optional type keeps the postfix `T?` (4.2). Its clash with `?`-suffixed identifiers
  is lexical: the lexer emits `Int?` as one identifier token and the parser splits the
  trailing `?` in type position. 4.2 records the rule and a required conformance test.
- Optionals never nest; lossy operations get documented unambiguous companions (4.5, 8.3,
  8.6).
- Overloading is deferred; named factory functions replace overloaded constructors, and
  mixed-type operators are deferred with it (7.3, 10.2, 11.5, 21).
- Type declaration bodies are braced only; the block-free to-EOF form is removed (10.6,
  14.3).
- Struct method capture keeps its value semantics and gains a teaching equivalence (7.5).
- String normalization happens at comparison; construction preserves the original bytes
  (9.2).

Section 24 no longer lists the optional spelling as an open roadmap item.

## Implemented so far

- `build.zig` provides `zig build`, `zig build test`, and `zig build run`.
- `src/Source.zig` is the immutable source-file record: UTF-8 with byte-order mark removal,
  LF and CRLF line handling, byte-offset spans, and one-based line and scalar-column
  mapping. It also locates the first invalid UTF-8 sequence and its span.
- `src/Diagnostic.zig` renders the canonical four-part shape from section 17.1, with the
  underline measured in scalars so it aligns past multi-byte characters. A runtime error
  also carries a stack trace, innermost call first, with runs of identical frames
  summarized.
- `src/Token.zig` holds the token kinds, the keyword table, and `canEndExpression`, which
  is the continuation-token list section 3.1 refers to. The switch is exhaustive, so a new
  kind cannot be added without classifying it.
- `src/Lexer.zig` produces tokens with spans: names, keywords, numbers, the three string
  forms, comments, operators, statement-terminating newlines, and EOF.
- `src/Ast.zig` is the syntax tree, free of runtime values so a future backend consumes the
  same tree the interpreter does.
- `src/Parser.zig` parses statements and expressions with section 5.3's precedence, and
  bounds nesting and tree height so no later pass can exhaust the host stack.
- `src/Resolver.zig` is name resolution: scopes, declarations, hoisting, and the section 6.1
  rules. These belong here rather than in the interpreter because they are properties of
  the text rather than of a run. It also records, per function, which module variables it
  reads and which functions it calls, for the checker.
- `src/Type.zig` is the static type representation, its compatibility rules, and function
  signatures.
- `src/Checker.zig` is type checking and flow analysis: inference, annotations, operand
  errors, section 4.1's definite assignment, and everything section 7 asks of functions.
- `src/Value.zig` holds `Nothing`, `Bool`, `Int`, and `Float`, implements section 9.4's
  display rules, and orders values.
- `src/Interpreter.zig` evaluates, applying section 5.3's result types and failure modes,
  and guards the host stack.
- `src/emerald.zig` is the library root. `check` and `run` share one pipeline that stops at
  the first stage to report anything, which is section 17.2's rule against cascades. The
  pipeline runs on a thread with a large reserved stack.
- `src/main.zig` implements `emerald check` and `emerald run` with the section 18.1 exit
  codes, including `2` for an uncaught runtime error.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `lexical/` must tokenize cleanly, `diagnostics/` must match their `.expected` exactly,
  `run/` must print theirs, and `runtime-errors/` must fail with theirs. See
  [conformance/README.md](../conformance/README.md) for how to add one.

### Function decisions worth knowing

This slice was first built with function bodies isolated from the module scope entirely, to
sidestep the problem that a hoisted function can run before a variable it reads is assigned.
That design was replaced before commit, because it contradicts section 6.1 (which presumes
module names are visible inside functions) and section 7.1 (functions capture surrounding
bindings), and because it rejected one of the most common programs a beginner writes: a
module-level `const` read by a function. Section 7.1 names the actual problem and the
actual rule — "hoisting never permits reading an uninitialized captured variable" — so
that rule is what is enforced instead. Do not reintroduce the isolation.

- **Visibility follows the text.** Functions are hoisted; variables are visible only below
  their declaration, inside function bodies too (section 7.1). A function sees the module
  variables declared above it. Using one declared below gets a diagnostic that says exactly
  that, rather than a generic "not defined".
- **Section 7.1's capture rule is checked statically, at each call made from top-level
  code.** Every module variable the callee reads, directly or through the functions it
  calls, must already be assigned there. Calls inside function bodies need no check of their
  own, since a caller's captures include its callees'.
- **Function bodies are checked after the top level**, against a view of the module scope in
  which everything counts as assigned: a function can run at any point, so the state at the
  place it happens to be written means nothing inside it. A body is checked early only when a
  call needs its inferred return type, and any gap in its view at that point is guaranteed to
  coincide with a capture error at that call.
- **Functions and variables share one namespace**, as section 7.3's "a name declares one
  function" implies. A program function may shadow a prelude function, as a variable may.
- Section 7.2 requires an explicit return type on a recursive function "so checking does not
  depend on circular inference". That is read here as applying only when there is something
  to infer: a recursive function with no value-returning `return` needs no annotation, since
  its type is "no result" without looking inside. **Needs a decision.** The spec pulls both
  ways: 7.2 says recursive functions "require" a return type, while the same section says a
  function with no result is one "whose annotation is omitted", distinct from one returning
  `Nothing`. An external review read it the strict way, and `: Nothing` is writable, so the
  strict reading is workable; an earlier version of this note wrongly said otherwise. The
  lenient reading is kept because the rule's stated reason does not apply and a recursive
  `countdown` is a common beginner program. Changing it is one branch in
  `Checker.signatureFor` plus the unit test "a recursive function with no result needs no
  annotation".
- Widening happens at calls too. The checker exports its signatures, including return types
  it inferred, and the interpreter widens arguments to parameter types and results to return
  types, so `return 1` from a function whose returns merged to `Float` yields `1.0`.
- **The host stack.** A probe showed the default stack exhausted between 600 and 800 calls
  in Debug, short of section 7.2's 1,000, so the whole pipeline runs on a thread with a
  512 MiB reserved stack (address space, not memory), and the interpreter raises before
  exhausting it whatever the program's shape. The parser bounds everything upstream: exactly
  256 levels of delimiter nesting (section 3.4, reported at the delimiter that crosses it),
  a separate budget for recursion that opens no delimiter, and a tree height of 10,000 so a
  long flat chain such as `1 + 1 + ... + 1` is a diagnostic rather than a crash. One unit
  test proves 1,000 calls at 250 levels of nesting in Debug; it peaks around 340 MB resident
  while it runs.
- **No fallback stack.** If the large-stack thread cannot be created, `emerald` exits `70`
  (internal failure) rather than running on the calling thread. Probing the old fallback
  showed nothing crashed on an 8 MiB main thread, but legal programs failed there, and the
  fallback had to assume a stack size the host chooses (1 MiB on Windows), which could make
  the guard wrong. Single-threaded builds are a compile error for the same reason.
- **Memory per call is freed.** Scopes, arguments, and the call stack come from the general
  allocator and are released as each block or call ends; only module bindings, hoisted
  functions, and the final failure live in the run's arena. This was done before loops,
  which would otherwise have grown memory with every iteration. A unit test pins it by peak
  memory: 32,767 calls must cost no more than 15.

### Review fixes

An external review of slice 7 found these, all verified by reproduction before fixing and
each now covered by unit tests and conformance cases:

- `true == true` and `nothing == nothing` passed checking and then failed at runtime. Every
  type now has `==` and `!=`; the ordering operators are rejected statically on anything but
  numbers (recorded in 5.2 of the rewrite context). When strings land, the "only numbers are
  ordered" diagnostic has to gain strings.
- `print` wrote each argument as it was evaluated, so an argument that printed interleaved
  with the line being built, and a failing argument left half a line. It now evaluates every
  argument first, like any other call.
- `-9223372036854775808`, the minimum `Int`, was rejected because its digits alone are out
  of range. The parser reads the minus and that literal together, but only when the minus
  applies to the literal alone: `-9223372036854775808 ** 2` is still out of range.
- `const limit: Int` was accepted though nothing could ever assign it. It is now rejected in
  the resolver, which runs before the checker, and later assignments to it are not reported
  again (recorded in 4.1 of the rewrite context).
- Stack fallback and per-call memory, described under the function decisions above.
- Not from the review: internal failures such as running out of memory escaped `main` as a
  raw Zig error with status `1`, colliding with source diagnostics. They now print one line
  and exit `70`, as section 18.1 specifies.

The review also restated the known Unicode identifier gap under "Known rough edges"; it is
still open.

### Checker decisions worth knowing

- Section 4.4 describes numeric widening as applying "where arithmetic requires it", but
  the same section relies on it to infer `[Float]` for `[1, 2.5]`, which is not arithmetic.
  It is read here as applying wherever a value meets an expected numeric type, so
  `var rate: Float = 1` is accepted. **Worth confirming**, since it is an interpretation
  rather than a quotation.
- Widening has to actually happen, not merely be permitted. Accepting `var rate: Float = 1`
  statically while storing an `Int` made `rate` print as `1` rather than `1.0`, with the
  static type and the runtime value disagreeing. The interpreter now carries the kind each
  name holds and converts on declaration and assignment.
- `count /= 2` where `count` is an `Int` can never type-check, because section 5.3 lowers
  `/=` through `/` and `/` always produces a `Float`. That is a consequence of two settled
  rules rather than a bug, but the cause is far from the line that fails, so it gets its own
  diagnostic naming the operator and suggesting `//=`.
- An expression whose type could not be determined becomes `Type.invalid`, which is
  compatible with everything. One mistake therefore produces one diagnostic instead of one
  per enclosing expression, which is section 17.2's rule against cascades.
- Definite assignment merges branches by intersection: a name is assigned after an `if` only
  when both a `then` and an `else` assign it. An `else if` chain without a final `else`
  proves nothing, because a path through it assigns nothing.

### Statement decisions worth knowing

- Name resolution is its own pass, so shadowing, undefined names, and assigning to a `const`
  are reported by `check` rather than only when a line happens to run.
- Section 3.4's brace style puts `else` on its own line, so a newline always sits between
  `}` and `else`. That newline terminates a statement everywhere else, so the parser looks
  past it only once an `else` is known to follow.
- The prelude is a scope of its own, below the program's. That is what lets a program
  declare a name matching a prelude function without it counting as the shadowing section
  6.1 forbids, matching the rule that a local may reuse a module-level name.
- A comparison chain is one node holding all its operands. That is what makes "evaluate the
  middle expression once" and "short-circuit as if joined by `and`" fall out naturally
  rather than being reconstructed by the evaluator.
- Section 4.4's mixed comparison rule rules out the obvious implementation: widening the
  `Int` to a `Float` first would make `9007199254740993 == 9007199254740992.0` true, which
  is the accidental equality the rule exists to prevent. `Value.order` splits the float
  instead.
- `Nothing` arrived with this slice rather than later, because `print` had been returning a
  placeholder `Int` that `var x = print(1)` would have exposed as a lie.

### Expression decisions worth knowing

- The right operand of `**` is parsed as a unary expression rather than as another power.
  That one rule gives the operator its right associativity, lets `2 ** -3` parse, and still
  leaves `-2 ** 2` meaning `-(2 ** 2)` because unary sits above it.
- Section 9.4's float display is written out in `Value.zig` rather than inherited. The host
  disagrees on every interesting case: it renders `2.0` as `2`, `-0.0` as `-0`, `1e16` in
  fixed form, and the special values as `inf` and `nan`.
- Zig's `@divFloor` and `@mod` were verified by probe to match section 5.3 exactly,
  including negative divisors and the law `a == (a // b) * b + (a % b)`.
- Section 5.2's rule that a standalone pure expression is an error is enforced in the
  parser, which is why a program is currently a sequence of calls.

### Lexical decisions worth knowing

- A newline is emitted only when the previous token can end an expression and no `(` or `[`
  is open. Braces deliberately do not open a group, so statements inside a block still end
  at a newline. Because `.newline` itself cannot end an expression, runs of blank lines
  collapse with no special handling.
- Section 3.3 lets a name end in `?` or `!`, which collides with `?.` and `!=`. A trailing
  marker joins the name unless the next character forms the operator, so `user?.name` and
  `a!=b` lex correctly while `empty?()` and `sort!()` keep their markers. The section 4.2
  conformance case `func valid?(): Bool?` is covered by a test.
- A `.` is a decimal point only when a digit follows, which is what keeps `5.times` a method
  call and `1..5` a range rather than malformed numbers.
- Documentation comments are tokens because the parser needs them. Line and block comments
  are skipped, which the formatter slice will have to revisit.

## Next concrete step

Per-call memory was the one prerequisite a review flagged for loops, and it is done.

Section 20's slice 8 is collections: a list literal, indexing, mutation, and one
higher-order method. Two things stand in front of it, and the order is worth deciding
before starting:

- **Loops.** No slice in section 20 names `while` or `for`, yet a collection slice without
  them is awkward, and definite assignment needs a rule for loops when they land. A small
  loop slice first is the recommendation.
- **Lambdas.** "One higher-order method" needs a block argument, which is section 7.4's
  lambda — deferred from this slice — and with it function values, capture by reference, and
  the trailing-lambda call form.

Collections are values, and the user confirmed that and tightened it (recorded in 4.3,
7.1, 8.1, 10.2, and a new "Decisions made during implementation" table in section 22):
`const` freezes a value entirely rather than only its binding, stopping at class
references; and parameters are read-only the same way, so mutating a collection parameter
is an error rather than a silent change to a discarded copy. What this means for slice 8:

- Store each collection as a reference-counted buffer with copy-on-write. Assignment and
  argument passing share the buffer; a mutation copies first only when it is shared. The
  checker already makes parameters read-only, so no new runtime rule is needed there.
- Nested updates such as `grid[0][1] = 5` must update in place, which needs assignable
  location paths in the interpreter; indexing needs them anyway.
- Reference counting reclaims collection storage completely until classes exist, because
  value-typed data cannot form a cycle. Once a class can hold a list that holds the class,
  a cycle can pass through the list, so the slice 9 collector must trace inside collection
  buffers too.
- Struct methods that mutate `self` must be identified from their bodies (no `mutating`
  keyword) so that calling one on a `const` or a parameter is rejected. That belongs to the
  object-model slice, but the collection mutators (`append` and the rest) need the same
  "mutates its receiver" flag from the start.

Still open: the leading-dot question below.

## Validation and blockers

- `zig build test` passes in Debug and ReleaseSafe: 155 unit tests, 50 conformance cases,
  and 7 command-line contract tests asserting the section 18.1 exit codes against the real binary. Every case kind was
  confirmed to fail when a case is broken, so none of them are vacuous.
- Every host-stack probe — 100,000 nested parentheses, 100,000 prefix minuses, a
  1,000,000-term flat sum, unbounded recursion, and 1,000 calls at 250 levels of nesting —
  ends in the right answer or a clean diagnostic, identically in Debug and ReleaseSafe.
- `conformance/diagnostics/definite-assignment.expected` reproduces the canonical diagnostic
  printed in section 17.1 character for character, apart from the path and position.
- Writing this slice found a leak worth remembering. Returning a struct that owns an
  `ArenaAllocator` by value copies the arena, and the copy snapshots the list of blocks it
  owns. Allocating into the arena inside the same struct literal that copies it therefore
  strands that allocation in the dead local. Finish every allocation before constructing
  the result; `analyze` and `Parser.parse` both do this deliberately.
- Writing the conformance suite immediately found a real defect. The standard streams were
  opened in positional mode, which starts at offset zero, so with output redirected to a
  file each diagnostic overwrote the one before it and only the last survived. Standard
  streams now use `writerStreaming`. Note that the defect is invisible when output goes to a
  terminal or a pipe, which is why the command-line contract tests did not catch it; the
  guard against a regression is the comment in `writeAll` plus the two-diagnostic
  command-line case, which at least proves both diagnostics are emitted.
- `bash tools/check-toolchain.sh` passes.
- Verified against the pinned standard library: `std.unicode` provides UTF-8/UTF-16
  encoding, decoding, validation, and code-point counting only — no grapheme segmentation
  and no normalization. Emerald must vendor UAX #29 and UAX #15 tables for grapheme
  indexing (9.1) and normalized equality (9.2). This is recorded in 19.1 and should be
  planned into the string slice, not discovered during it. `std.fmt` does provide
  shortest-round-trip float formatting, satisfying 9.4.
- Zig 0.16 API notes worth not rediscovering: `zig env` emits ZON rather than JSON;
  `std.fs` is deprecated in favor of `std.Io.Dir`; `std.process.argsAlloc` is gone and
  `main` instead takes a `std.process.Init` supplying the allocator, `Io`, and arguments;
  `addExecutable` and `addTest` take a `root_module` built by `b.createModule`.

### Open question raised by writing the conformance cases

Section 3.1 decides continuation from the preceding tokens only, explicitly "rather than
indentation or the next line". That rules out the leading-dot method chain that Kotlin,
Swift, and C# all allow:

```emerald
var count = numbers
    .filter { number => number > 0 }
    .count
```

As written, the newline after `numbers` ends the statement, because an identifier can end an
expression. This matters more for Emerald than for most languages, because section 5.4 makes
method chaining the pipeline notation and declines a separate pipeline operator, so long
chains are the idiomatic style and will want to wrap. Supporting it means letting a leading
`.` on the next line continue the previous statement, which is a deliberate exception to the
"preceding tokens only" rule rather than an oversight in it. A conformance case was written
using this form and then removed, since the rule as written rejects it.

This needs a decision before the parser slice fixes the behavior by accident.

### Deferred

- From section 7: nested functions (rejected with one diagnostic), lambdas and trailing
  blocks, function values (a bare function name is rejected, though section 3.4 makes it the
  callable value), default parameters and named arguments, and variadics (already deferred
  in the spec). A top-level `return`, which section 14.1 uses to end the program, is
  rejected outside a function for now.
- Section 14.1's warning for unreachable code after a `return`. Diagnostics have no
  severity yet; until they do, code after two branches that both return is treated as
  assigned everything rather than reported.
- Section 6.2's `unless` block form, the one-line modifier guards, and the
  `if ... then ... else` expression. The `unless not condition` style diagnostic also needs
  a severity on `Diagnostic`, which does not exist yet.
- Optional types. The parser splits the `?` in type position as section 4.2 requires, and
  the checker reports that optionals are not available yet, so the rule is exercised without
  the semantics existing.
- String literals in expressions. The lexer produces the tokens, but nothing consumes them,
  so `conformance/lexical/strings.em` has not graduated.
- Loops. Section 20 does not name them in a slice of their own; they belong with or just
  after functions, and definite assignment will need a loop rule when they land.

### Known rough edges

- The capture check is conservative. It flags a call if the callee could read an
  unassigned variable on any path, even one this particular call cannot take. Moving the
  call below the variable is always the fix, and the diagnostic says so.
- Definite assignment at the top level does not see assignments made inside a called
  function. `var total: Int`, then a call to a function that sets it, then a read, is
  rejected as possibly unassigned. Initializing the variable is the fix.
- Past the 256th brace, parse recovery can report the unconsumed closing braces as further
  errors. Only a program that is already rejected for its nesting can see this.
- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.
- String interpolation is not scanned yet, so a `"` inside `#{...}` ends the string early.
  Strings are lexed as whole tokens and left uncooked; escape processing, indentation
  stripping for triple-quoted strings, and interpolation all belong to one later slice.
- Identifier characters are currently any ASCII letter, digit, underscore, or any non-ASCII
  byte. Section 3.3 specifies Unicode XID classes with NFC normalization and no emoji, which
  needs the tables section 19.1 schedules for the string slice. Accepting too much now and
  tightening later keeps valid programs valid.
- A multi-line block comment joins the lines around it rather than terminating a statement,
  matching how C-family languages treat their block comments.

## Pending changes

None. Verify against Git before continuing.
