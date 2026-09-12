# Current handoff

Updated: 2026-09-11. Prepared by Claude after the optionals slice.

## Current milestone

Slices 1 through 10 of section 20 are complete, plus a loop slice the user approved
inserting before slice 8, a string slice the user chose to do before slice 9, and an
optionals slice the user chose to do before the project slice. Section 20 was renumbered
during the callable slice: the old slice 9 bundled closures with the collector, and they
are now slice 9 (callables) and slice 10 (the managed heap). The whole frontend pipeline of
section 19.2 exists: source manager, lexer, parser, name resolver, type checker,
interpreter.

Functions work: declarations, calls, returns, recursion, hoisting, return-type inference,
and stack traces on runtime errors. Loops work: `while`, `for` over an `Int` range, `break`,
`continue`, and the trailing `if` guard. Lists work: literals, indexing, element assignment,
the essential methods, equality, printing, and `for`, with value semantics through
copy-on-write. Strings work: literals with escapes and interpolation, triple-quoted
layout, Unicode-aware counting, indexing, iteration, comparison, and case mapping, the
section 9.2 methods that need no optionals, and `input` and `write`, so section 2's first
program runs. Callables work: lambdas with inferred or written parameter types, closures
that capture by reference, function types, named functions as values, the trailing-block
call form, and `each` and `map`. Optionals work: `T?`, `nothing`, narrowing by comparison
against `nothing`, `.or(...)`, and the vocabulary that needed them — `first`, `last`,
`find`, `find_index`, `index_of`, the `_maybe` parsers, and `input_maybe`. Memory is
managed: reference counting reclaims promptly
and section 19.5's mark-and-sweep collector reclaims the cycles counting cannot, so a loop
that keeps making blocks runs in flat memory. Every expression has a static type before
execution and
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
- `src/Type.zig` is the static type representation, its compatibility rules, function
  signatures, and the list method table the checker and interpreter share.
- `src/Checker.zig` is type checking and flow analysis: inference, annotations, operand
  errors, section 4.1's definite assignment, and everything section 7 asks of functions.
- `src/Value.zig` holds `Nothing`, `Bool`, `Int`, `Float`, and lists, implements section
  9.4's display rules, and compares and orders values.
- `src/Heap.zig` owns list buffers, string texts, scope environments, and closures:
  reference counts, copy-on-write, and section 19.5's mark-and-sweep collector, which walks
  the lists of every live object and reclaims the cycles counting cannot.
- `src/unicode.zig` is Emerald's Unicode: grapheme clusters (UAX #29), NFC normalization
  and its quick check (UAX #15), full case mapping with Final_Sigma, and identifier and
  whitespace classes. Its data is `src/unicode/tables.zig`, generated from Unicode 17.0.0
  by `tools/unicode/generate.zig`; `src/unicode/test/` embeds Unicode's conformance data.
- `src/strings.zig` holds section 9's string operations on UTF-8 bytes: character-aware
  searching, splitting, trimming, substrings, and strict number parsing.
- `src/Interpreter.zig` evaluates, applying section 5.3's result types and failure modes,
  and guards the host stack. Block and call scopes come from the general allocator and are
  reused once emptied, so a running loop does not allocate.
- `src/emerald.zig` is the library root. `check` and `run` share one pipeline that stops at
  the first stage to report anything, which is section 17.2's rule against cascades. The
  pipeline runs on a thread with a large reserved stack.
- `src/main.zig` implements `emerald check` and `emerald run` with the section 18.1 exit
  codes, including `2` for an uncaught runtime error and `70` for an internal failure. It
  chooses the fast `smp_allocator` outside Debug builds; see the loop decisions below.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `lexical/` must tokenize cleanly, `diagnostics/` must match their `.expected` exactly,
  `run/` must print theirs, and `runtime-errors/` must fail with theirs. See
  [conformance/README.md](../conformance/README.md) for how to add one.

### Optional decisions worth knowing

- **An optional is a flag on the type, not a wrapper.** Section 4.5 settles that optionals
  never nest, so there is nothing a second layer could mean and no way to build one by
  accident. `Int?` costs exactly what `Int` costs, and at runtime an optional is simply the
  value or `nothing` — no boxing, no allocation, nothing for the collector to trace.
  Placement stays structural: the flag on a list is `[String]?`, the same flag on its
  element is `[String?]`.
- **Narrowing lives in the same state that definite assignment lives in.** `Snapshot` grew
  from a bool per binding to `{ assigned, type }`, so every place that already saved,
  restored, intersected, or merged flow state now does the same for what narrowing proved.
  That is what makes narrowing stop at the end of a branch, at a loop, and at a `break`
  without any of those places knowing about optionals.
- **A `var` a block assigns to is never narrowed.** Section 4.5 says the proof is lost when
  "a called closure could reassign its captured binding". The resolver already walks lambda
  bodies, so it records `assigned_in_lambda` and the checker refuses to narrow those names
  at all. A `const` and a parameter always narrow, because they cannot be rebound.
- **`.or(...)` is lazy and is the one method allowed on a value not yet proved present.**
  Supplying the fallback is what proves it. The fallback is evaluated only when it is
  needed, matching the `or` operator's short-circuiting.
- **Every place that reached into a value had to learn to ask first.** `requirePresent`
  guards member access, indexing, method calls, iteration, and element assignment. Two of
  those were found by trying them rather than by reading: `for x in maybe_list` and
  `maybe_list[0] = 1` both crashed the interpreter before the guards went in.

### Collector decisions worth knowing

- **The roots are derived, not registered.** Section 19.5 asked for an explicit root API,
  which would mean registering every temporary the evaluator holds across an allocation.
  The counts already say the same thing and say it more safely: every holder retains, a
  count may be too high but never too low, so an object whose count exceeds the references
  coming from other managed objects is held by something outside the heap. That is exactly
  the root set, including every `Value` sitting in a Zig local. The decisive argument is
  the failure mode — a missed registration frees a live object, while a count that is too
  high only delays a free. Recorded in 19.5 and in section 22.
- **Literal strings are roots.** They are never counted, so counting holders of one would
  make it look like garbage. `collect` marks every `literal` text unconditionally.
- **Sweeping drops the garbage's references to survivors.** A dead cycle can hold a live
  string; freeing the cycle without decrementing would keep that string for the whole run.
  The sweep does that in a pass before it frees anything, so no free cascades into another.
- **Tracing can fail.** The worklist needs memory. When it cannot grow, `collect` returns
  having freed nothing, which is always correct — the heap is exactly as it was.
- **Collection happens before allocating, not after.** Called at the top of each `create`,
  so a half-built object is never exposed to a trace.
- **How it was verified.** The whole suite, every example, and every conformance case were
  run with the threshold forced to collect before every single allocation, in Debug and
  ReleaseSafe. Each collector test was also confirmed to fail with the sweep disabled or
  the list roots removed, so none of them is vacuous.

### Callable decisions worth knowing

- **A scope is an object, not a stack frame.** Section 7.4 captures by reference, so a block
  and the code around it must keep sharing one variable. `Heap.Environment` is counted like
  a list; `popScope` recycles it only when nothing captured it, so a loop body that creates
  no closure still allocates nothing. A closure holds the whole visible scope chain rather
  than a computed capture set, which costs one pointer per enclosing block and needs no
  analysis in the resolver.
- **Why the collector became its own slice.** Counting reclaims everything the earlier
  slices can build, because value-typed data cannot form a cycle. A closure can: store a
  lambda in a variable it captures and the closure and the environment hold each other
  forever. The collector arrived in the next slice and now reclaims exactly that.
- **The parser decides a lambda's body shape from the source, not a token.** `=>` continues
  a line like any other operator, so the lexer has already dropped the newline after it.
  `brokeLine` reads the bytes between `=>` and the next token instead. This was a real bug:
  every block-bodied lambda parsed as an expression body until it was found.
- **A named function value and a lambda are one runtime kind.** `Heap.Closure` holds either,
  and `closureCallable` turns both into the same `Callable`, so `invoke` is the only place
  that knows how a call works. `callFunction` is just the direct-call shortcut that skips
  building a closure.
- **`each` and `map` are checked directly rather than through the method table.** Their
  argument and result types are both stated in terms of the receiver's element type, and
  `map`'s result comes from the block, which `Type.ListMethod`'s fixed operand enum cannot
  express. A function type whose result is `invalid` is how the checker asks for a block
  without constraining what it produces.
- **The checker records a lambda's type in `literal_types`.** It is the only place the
  parameter and result types are known, and the interpreter needs them to widen arguments
  and results the way section 4.4 allows, exactly as it reads a named function's signature.

### String decisions worth knowing

- **Unicode is generated, not hand-written.** `tools/unicode/fetch.sh` downloads the
  database, `tools/unicode/generate.zig` writes the tables (then `zig fmt` them), and
  `zig build unicode-conformance -Doptimize=ReleaseSafe -- <dir>` checks the whole
  NormalizationTest: 20,034 cases plus the rule that every one of 1,094,978 unlisted code
  points is its own NFC, with no failures. Regenerating reproduces the committed tables
  exactly. The routine suite embeds all 766 GraphemeBreakTest cases and every
  NormalizationTest part but Part 1, which is 2.8 MB.
- **The lexer emits an interpolated string in parts** (`string_start`, `string_middle`,
  `string_end`) around ordinary expression tokens, tracking a stack of open
  interpolations and the braces inside each, so quotes and braces inside `#{...}` belong to
  the expression. A string that began inside an interpolation and ran off its line is
  reported as the unclosed `#{`, which is almost always the real mistake.
- **The parser cooks strings once**: escapes, `\u{...}`, triple-quoted layout, and
  Windows line endings. The AST holds finished text. Triple-quoted layout errors (text on
  the opening line, a closing delimiter sharing a line, a line indented less than the
  closing delimiter) are all parser diagnostics.
- **Names are XID and NFC.** The lexer accepts Unicode identifier characters (which leave
  out emoji, so no separate emoji rule is needed) and the parser normalizes any name not
  already in NFC at the one place every stored name passes through, `Parser.identifier`.
  The long-standing rough edge about accepting any non-ASCII byte is closed.
- **Strings are immutable heap texts** with counts, sharing freely. A literal's text lives
  in the syntax tree and is wrapped once per literal as a "literal" text that is never
  counted, so a loop printing a literal does not allocate.
- **Equality and ordering normalize only when they must.** Identical bytes are equal, two
  strings the quick check says are already NFC compare as bytes, and only otherwise is
  anything normalized. `Value.equals` now takes an allocator for that reason.
- **Searching respects characters** (recorded in 9.2): matches must start and end on
  grapheme boundaries of the normalized haystack, so `"café".contains?("e")` is false.
- **`+` joins strings** and `+=` appends (user decision pending confirmation; recorded in
  the section 22 table). A reference-count bug was caught while adding it: `applyBinary`
  released its operands, but compound assignment passed a binding's value unretained. Now
  no operator releases operands; callers own them, and compound assignment holds the
  current value while the right side runs, since that could reassign the same name.
- **`input` reads from a stream the CLI passes in**, and the conformance runner feeds a
  `.input` file beside a case. End of input is a runtime error until optionals bring
  `input_maybe`; so is a line that is not valid UTF-8.
- **Stack budget.** Adding cases to `evaluate` pushed its Debug frame past what 1,000
  calls at 250 levels of nesting fit in; the fix, now a comment in `evaluate`, is that
  every case needing locals lives in a function of its own.
- Performance: 200,000 interpolations with `upper` and 50,000 `contains?` calls run in
  0.7 s in ReleaseSafe.

### List decisions worth knowing

- **Scope** (user-approved): lists only. Dictionaries and sets need string keys to be
  useful, and `first`, `last`, and `each` need optionals and lambdas.
- **Value semantics are reference counts with copy-on-write** (`Heap.zig`), as planned. A
  "shared bit" cleared only by a future collector was considered and rejected: passing a list
  to a function would mark it shared for good, so a loop calling `f(xs)` then
  `xs.append(i)` would copy the whole list every iteration. With counts, 200,000 such
  iterations take 0.09 s. The rule the interpreter follows: every new holder retains (a name
  read, a retained element, a loop snapshot), every holder that ends releases (a scope
  closing, an overwritten binding, a consumed temporary). Counts may run high, which only
  costs a copy; they must never run low. Every buffer is also linked into `Heap.live`, and
  `Heap.deinit` frees whatever is left, so error paths cannot leak. A unit test pins flat
  memory, and was confirmed to fail when `popScope` stops releasing.
- **A buffer records its element kind**, because runtime has no static types but a `[Float]`
  must store `rates.append(2)` as `2.0`. List literals get their element type from the
  checker's `literal_types` table, which is how `var rates: [Float] = [1, 2]` stores
  Floats.
- **Expected types flow into list literals** (`typeOfExpected`): from annotations,
  assignment targets, parameters, method arguments, return types, and the other side of a
  comparison. Only literals use them. Without context, a literal infers its element type and
  widens `Int` beside `Float`; `[[1], [2.5]]` without an annotation is rejected, since the
  inner lists are typed before they meet. Lists are invariant everywhere else, with their
  own correction.
- **Where a list changes**: element assignment and mutating methods evaluate their indices
  and arguments first, then walk to the target, making each list on the way unique. Walking
  afterwards is what keeps a pointer valid when evaluating the value itself changes the list.
- **Mutation is checked in the checker, not the resolver**, because whether a method mutates
  depends on the receiver's type. Checker bindings carry a `Mutability`, and each reason a
  change is refused has its own correction: `const`, parameter, loop variable, or a temporary
  like `make().append(1)`.
- **Unknown members suggest Emerald's name** for another language's (`push` → `append`,
  `length` → `count`), and `count()` and a bare `append` explain properties versus methods.
- **`5..1` is now an error** (the user chose error over warning, recorded in 6.4), for two
  literal endpoints only.
- **Counting down** (user-approved, recorded in 6.4): `a.down_to(b)`, `a.up_to(b)`,
  `.step(n)`, and `.reverse()` are loopable directly, alongside ranges. A wrong-side target
  counts nothing, which replaced the spec's earlier "error on a wrong-side target" rule so
  computed bounds stay safe in both directions; two literals that can only be empty are an
  error. `Checker.isCounting` recognizes these forms by shape, since none is a value a
  program can hold yet, and the interpreter normalizes each to a `Counting` whose `last` is
  a value the count actually reaches, so the loop stops by comparing and never steps past
  either end of the `Int` range, and `reverse` swaps ends exactly.
- **Member access and indexing** are postfix operators chained with calls, so
  `grid[0].append(1)` and `make()[0]` parse; `?.` reports that optional chaining is not
  available yet.

### Loop decisions worth knowing

- **Definite assignment through loops** (recorded in 6.4). A body is checked from the state
  before the loop, which is exact for the first iteration and conservative for later ones,
  since nothing becomes unassigned. After a loop, only what was assigned before it is known,
  because the body may run zero times; a name lost that way gets its own correction ("the
  loop that assigns `x` might not run at all"). A literal `while true` is the exception:
  after it, a name is assigned when every `break` assigned it (`Checker.Loop.exits`), and
  one with no `break` never completes, so a function may end in it.
- **"Always returns" became "completes".** The checker's control-flow shape now asks
  whether a block can fall off its end (`blockCompletes`), so a branch ending in `break` or
  `continue` is left out of the merge after an `if` exactly as a returning one was, and the
  every-path-returns check accepts a body ending in `while true`.
- **Trailing `if` is parsed into an ordinary `if`** with no `else` whose block holds the one
  statement, flagged `trailing` for the future formatter. No pass after the parser treats it
  differently. It is accepted after calls, assignments, `return`, `break`, and `continue`, and
  rejected after a declaration. `return if cond` is a bare return with a guard; when the
  `if ... then ... else` expression lands, `return if a then b else c` will need to be told
  apart by looking for `then` on the same line.
- **Ranges are ordinary expressions** at their own precedence level, between comparison and
  arithmetic, so `0..count - 1` ends at `count - 1`. The checker accepts one only as what a
  `for` loop visits, and the interpreter reads its endpoints there directly rather than
  building a range value. `for` stops by comparing with the last value, so a range ending at
  the largest `Int` does not overflow.
- **`break` and `continue` unwind as Zig errors** (`Broke`, `Continued`), the same way
  `return` already did; the checker guarantees a handler for each, and a function body starts
  with no enclosing loop.
- **Parse recovery skips a whole block** when the failed line opened one, so a broken loop or
  `if` header no longer reports its closing brace as a second error. A stray top-level `}`
  now says it closes nothing.
- **Performance, found by timing the first long loops.** Zig 0.16 gives a ReleaseSafe build
  without libc its leak-checking `DebugAllocator` as `init.gpa`, which made a loop that
  declares a local about 7 µs per iteration. `main` now uses `std.heap.smp_allocator` outside
  Debug, and the interpreter reuses emptied scope tables. Ten million iterations went from
  39 s to about 1 s in ReleaseSafe, with flat memory. The remaining cost is name lookup
  through hash maps; resolving names to slots is the obvious next step if it matters.
- **The leading dot** (recorded in 3.1) is implemented in the lexer
  (`nextLineLeadsWithDot`). Member access itself is not parsed yet, so it is covered by a
  lexical conformance case until the collection slice.

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
- A function with no result returns `Nothing`, and a recursive one needs no annotation,
  since its return type is known without inference. The user settled this (7.2 now says
  so directly), replacing a "no result" category that differed from `Nothing` in name
  only.
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
  conformance case `func valid?(input: Int?): Bool` is covered by a test.
- A `.` is a decimal point only when a digit follows, which is what keeps `5.times` a method
  call and `1..5` a range rather than malformed numbers.
- Documentation comments are tokens because the parser needs them. Line and block comments
  are skipped, which the formatter slice will have to revisit.

## Next concrete step

Section 20's slice 11, the project slice: `main.em`, multiple files, namespaces, and
`using`. Section 14.1's project-detection rule is settled and recorded, and nothing else
now blocks it. It is the last slice before the object model, which is by far the largest
remaining piece and which everything after it depends on.

The alternative is dictionaries and sets from section 8. They are the last collections
missing, optionals have just unblocked dictionary lookup, and they need no new machinery
beyond the literal syntax already reserved in 8.2. They would make the standard library
feel complete before the object model reshapes everything.

Recommend the project slice, because multiple files is the thing a growing program hits
first, and because leaving it until after the object model would mean reworking namespaces
around types rather than the other way round.

## Validation and blockers

- `zig build test` passes in Debug and ReleaseSafe: 255 unit tests, 107 conformance cases,
  and 7 command-line contract tests asserting the section 18.1 exit codes against the real
  binary. Every case kind was confirmed to fail when a case is broken, so none of them are
  vacuous.
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

### Deferred

- From section 7: nested function declarations (rejected with one diagnostic; a lambda in a
  variable does the same job), default parameters and named arguments, variadics (already
  deferred in the spec), tuple destructuring in a lambda parameter, and capturing a built-in
  such as `print`, which no written function type describes. A top-level `return`, which
  section 14.1 uses to end the program, is rejected outside a function for now.
- Section 14.1's warning for unreachable code after a `return`. Diagnostics have no
  severity yet; until they do, code after two branches that both return is treated as
  assigned everything rather than reported.
- Section 6.2's `if ... then ... else` expression. `unless` is no longer part of the language
  and is not a keyword.
- From section 8: dictionaries and sets (the bracket parser reports "dictionaries are not
  available yet" at a `:`), the rest of section 8.6's rich vocabulary beyond `each`, `map`,
  `find`, and `find_index`, slicing with ranges, `type_name`, and a mutating method through
  a struct field, which arrives with structs.
- Range values: ranges and counts stored in names, `random(1..6)`, and the block forms of
  `up_to`, `down_to`, and `times` are rejected ("a range can only be looped over so far")
  until range values land. Blocks now exist, so only the range value itself is missing. In a
  `for` header every counting form works.
- Section 4.5's optional chaining, `?.`. It exists to shorten chains through objects, and
  there are no objects yet, so there is nothing for it to reach through; the parser reports
  it and points at narrowing and `.or(...)`.
- From section 9: `pad_start`, `pad_end`, and `pad_center` (their
  signatures need default arguments), `insert_at`, `remove_prefix`, `remove_suffix`,
  `collapse_repeats`, `partition`, `letter?` and `digit?` (general category tables),
  `code_points` and `bytes`, string slicing with ranges, and `type_name`.

### Known rough edges

- The capture check is conservative. It flags a call if the callee could read an
  unassigned variable on any path, even one this particular call cannot take. Moving the
  call below the variable is always the fix, and the diagnostic says so.
- Definite assignment at the top level does not see assignments made inside a called
  function. `var total: Int`, then a call to a function that sets it, then a read, is
  rejected as possibly unassigned. Initializing the variable is the fix.
- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.
- Indexing a string by character is linear, as section 9.1 accepts, so
  `for i in 0..<s.count { s[i] }` is quadratic. `for character in s` is the linear way, and
  a cached boundary index is the fix if real programs need it.
- A string's searching methods return text built from the normalized haystack when the
  haystack was not already NFC, so `replace` on decomposed text yields composed text.
  Canonically this is the same string, but the bytes differ from the input.
- A multi-line block comment joins the lines around it rather than terminating a statement,
  matching how C-family languages treat their block comments.
- Closures in a loop no longer grow memory. The same measurement that showed 155 MB for
  200,000 iterations of `const block = { => i }` before the collector now shows 3.4 MB, and
  the program got faster rather than slower (0.09 s against 0.17 s) because it allocates
  less. The threshold is 4,096 live objects, doubling to twice the surviving count after
  each collection.
- The capture check does not follow a function reached through a value. `const f = later`
  then `f()` above a module variable `later` reads is not reported the way a direct call is;
  the interpreter's unassigned-read error catches it at runtime instead. Extending
  `checkCaptures` to callable values would need the checker to track which function a
  variable holds.

## Pending changes

None. The optionals slice is committed. Verify against Git before continuing.
