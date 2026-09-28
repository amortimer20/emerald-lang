# Startup performance: design and implementation plan

Status: accepted, 2026-09-28; the user asked Claude to carry it out. The measurements below were
taken on `main` before and after the HTTP milestone merged (`b7440da`, `c3b830b`). The
executor makes the remaining judgement calls within a slice, and records each one under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## The problem

Every run of every program, including `print(1)`, lexes, parses, resolves, and type-checks
the whole prelude: the 1,965 lines of Emerald that implement `Date`, `Regex`, `Json`, `Http`,
`Console`, and the rest. A ReleaseSafe `print(1)` has grown from about 5.6 ms before the date
library to 9.8 ms now, and every library adds more. Students on a classroom platform run
small programs constantly, so startup is most of what they wait for.

## Measurements

ReleaseSafe `emerald run` of `print(1)`, median of 40–60 runs, on the development machine
(WSL2, 7 GB). Stage times come from temporary timing marks (not committed; see "Measuring").

| Stage | Time | Page faults |
| --- | --- | --- |
| Finding the local time zone | 0.05 ms | 16 |
| Loading the program and prelude sources | 0.40 ms | 113 |
| Lexing | 0.61 ms | 51 |
| Parsing | 1.00 ms | 313 |
| Resolving names | 1.03 ms | 165 |
| Checking: registering declarations | 0.36 ms | 115 |
| Checking: struct shapes and key annotations | 0.23 ms | 33 |
| **Checking: function and method bodies** | **4.8–5.1 ms** | **1,413** |
| Checking: which methods change their receiver | 0.05 ms | 2 |
| Running `print(1)` | 0.31 ms | 88 |
| Outside the stages (setup and teardown) | about 0.8 ms | |
| Process start and exit (`emerald --version`) | 0.53 ms | |
| **Total** | **9.7–9.8 ms** | **about 2,500** |

What the numbers say:

1. **The prelude is nearly all of it.** The program is one line; about 7.7 ms is front-end
   work on the prelude, identical on every run.
2. **Checking bodies is half the total,** and it is spread across the library, not one hot
   spot. By declaration: `Json` 1.35 ms, `Duration` 0.58, `Regex` 0.50, `Time` 0.43,
   `Console` 0.37, `Date` 0.33, `Instant` 0.32, `DateTime` 0.31, then a long tail. A single
   body can look expensive (`Json._listed_keys` measured 382 µs) because it happens to pay a
   one-time cost; the same code in a user program checks in about 35 µs.
3. **Memory is a large part of the cost.** A `print(1)` touches about 10 MB and takes about
   2,500 page faults; the process spends as long in the operating system (3.6 ms) as in its
   own code (4.0 ms). Checking bodies alone takes 1,413 faults, about 5.6 MB, or roughly
   24 KB per body. Page faults are slow under WSL2 in particular, but fewer allocations help
   everywhere, including large student programs.
4. **Not the problem:** the local time zone lookup (0.05 ms), the allocator (release builds
   already use `smp_allocator`), and `moduleView`, which an earlier fix already slimmed.

## Levers, in order

1. **Check only the prelude bodies a program can reach.** Declarations and signatures are
   still registered for every prelude name, since the program may use any of them, but a
   body is checked only when it can run. `print(1)` reaches no prelude bodies at all.
   Expected: most of the 4.8 ms and 1,400 faults, about half of the total. This is the main
   change and needs the design below.
2. **Allocate less while checking.** About 24 KB per body is a lot. Find where it goes with
   a counting allocator (by call site), then cut the largest: likely candidates are the
   strings built for every method-key lookup (`Resolver.methodKey` allocates each time), scope
   copies made for branches, and repeated `Type` construction. This helps every program,
   including the reachable prelude bodies that lever 1 still checks.
3. **Skip freeing memory at exit in release builds.** The operating system reclaims it all
   at once. Part of the roughly 0.8 ms outside the stages is teardown; measure how much
   before and after.
4. **Lex and parse the prelude once, when Emerald is built,** instead of on every run: about
   1.6 ms and 360 faults. This needs a serialized AST or a comptime parse, which is a larger
   change. Revisit with fresh measurements after 1–3; it may not be worth it.

## Design for lever 1: reachable prelude bodies

The rule has to be conservative: any prelude body that can run must have been checked, since
the interpreter relies on facts the checker records inside each body (method selections,
literal types, JSON shapes, operator choices, and others, keyed by AST node). A body that is
never checked has no facts and must never run.

Proposed rule, for the executor to confirm against the code:

- **A prelude type is reached** when checked code (the program, or a reached prelude body)
  mentions it: in an annotation, as the inferred type of any expression, or in the signature
  of a reached function. Reaching a type checks all of its bodies: methods, properties,
  constructor, field defaults, type-level functions, and nested types. Checking a type as a
  whole is simple, and still skips every type a program never touches.
- **A prelude function is reached** when checked code calls or names it.
- **Reaching is transitive:** checking a reached body can reach more types and functions.
  Repeat until nothing new is reached.
- **Indirect entry points count.** A value of a reached type can run its `to_string`
  (through `print` and interpolation), `equals` and `hash` (through `==`, dictionaries, and
  sets), comparison (through `<` and sorting), and `@operator` methods. Since reaching a type
  checks all its bodies, these are covered. A trait default (`Textual`, `Ordered`) is
  reached with any type that adopts the trait.

Safety nets, both required:

- **The whole prelude is still checked in tests.** Otherwise a mistake in a rarely reached
  prelude body would go unnoticed until a program happened to reach it. `zig build test`
  checks every prelude body once, and fails on any prelude diagnostic.
- **Running an unchecked body stops Emerald with a clear panic** naming the body, in every
  build mode, since it can only be a mistake in the reachability rule. It never silently
  runs with missing facts.

Also check the other analysis paths: the LSP and REPL analyze through their own entry points
and may rely on every prelude body being checked, for hover or completion; they can keep
checking everything if they need to, since neither is on the startup path of `emerald run`.

## Measuring

- **`tools/startup-benchmark.py`** runs built binaries on five programs (`print(1)`, one
  using only the language, and one each reaching dates, regular expressions, and JSON),
  reporting the median wall time, user and system time, and page faults. Absolute times drift
  badly on the development machine: the same binary measured 9.8 ms in one hour and 22 ms in
  the next. So compare a change by passing two binaries (before and after); their runs
  alternate, so drift affects both alike, and the tool reports the second as a share of the
  first. Record the comparison in the journal after every slice.
- **Stage timing** used temporary marks around each stage in `emerald.analyze` and each
  phase in `Checker.check`, printing elapsed time and `getrusage` page faults. Do not commit
  them; add them locally to find where a slice's time goes.
- **Build with `-j1`** on this 7 GB machine when another build may be running; parallel
  builds have run it out of memory.

## Slices

1. **The benchmark tool and baseline.** `tools/startup-benchmark.py`, and the baseline
   recorded in the journal.
   Done: the tool compares two binaries by alternating their runs, after an hour-to-hour
   drift of more than two to one made absolute times useless for comparison.
2. **Reachable prelude bodies** (lever 1), with both safety nets, conformance showing a
   program reaching dates, regular expressions, JSON, HTTP, and a trait default, and the
   benchmark before and after.
   Done. `Checker.reachKey` marks the top-level prelude type or function a key belongs to;
   `typeOf` reaches every prelude type an expression's type holds (walking struct fields and
   base classes once each), and calls, qualified names, and method calls reach their owners.
   The program's own structs are walked before its statements are checked, since printing or
   encoding one runs its fields' bodies. The prelude's traits declare only abstract methods,
   so no trait default needed handling. The interpreter stops with a panic naming the body if
   a prelude function, constructor, or field default outside the reached set would run, and a
   unit test checks the whole prelude, which was shown to catch an error planted in a body
   `print(1)` does not reach. `run/prelude-reach` exercises each indirect way in: a field's
   type, a base class, a type-level function returning `String`, an enum value, sorting, and
   decoding. Against `main` (`c3b830b`), alternating runs: `print(1)` 9.87 → 5.09 ms (52%),
   page faults 2,508 → 1,056, system time 4.2 → 1.2 ms; a language-only program 55%; JSON
   62%; dates 77%; regular expressions 81%.
3. **Fewer allocations while checking** (lever 2), guided by a counting allocator, with the
   largest sources recorded in the journal and the benchmark before and after.
   Investigated, not yet changed. After slice 2, `print(1)`'s stages are: loading sources
   0.42 ms, lexing 0.62, parsing 0.96, resolving 1.00, checking 0.68, running 0.28, and
   teardown 0.24, plus about 0.5 ms of process start and exit. Checking now matters for
   programs that use a library: `examples/regex.em` spends 3.5 ms and about 1,050 page faults
   in it. A counting allocator over the checker's arena (Debug build, stack traces resolved
   with `addr2line -f`, since it cannot read Zig's line tables but does recover function
   names) found 4.3 MB in 5,723 allocations for that program. The largest sources:
   - `moduleView`, 1.45 MB in 151 allocations: every body checked gets a fresh map copying
     every module-level variable of the program, about 9.6 KB each here. Its cost grows with
     the product of a program's functions and its globals.
   - `snapshotOf`, 860 KB in 888 allocations: every branch and loop copies the state of
     every scope in view, the copied module view included.
   - Growing hash maps in `registerStruct` (376 KB) and the expression-type maps.

   The fix is to give each body only the module variables it uses. The resolver's
   `module_reads` records a body's direct reads, but not reads inside its lambdas
   (`lambda_reads`), and the view's contents feed definite-assignment and narrowing, whose
   snapshots are positional, so a variable cannot be copied lazily on first use. It needs
   its own careful slice, with conformance aimed at definite assignment and narrowing in
   lambdas, nested functions, and assignments to module variables. It is worth about a
   millisecond for programs that use a library, and nothing for `print(1)`.
   Done in a later session. The resolver now records, per function body (keyed by its
   statements), every module variable used anywhere inside it: read or assigned, in its own
   statements, its lambdas, or its nested functions, recorded in every enclosing body.
   `moduleViewFor` copies only those. A body with no statements (field defaults are checked
   as one) or one the resolver did not walk still gets the whole view. If a body ever reaches
   a module variable its record lacks, `Checker.requireInView` panics, naming it; that net
   caught the field-default case on its first run. `run/module-variables-in-bodies` covers
   reads, assignments, narrowing, a lambda, a nested function, and destructuring. Against
   `main` (`18d0c9b`): dates 85%, regular expressions 84%, JSON 94%, `print(1)` unchanged;
   the regular-expression program's page faults fell from 1,996 to 1,472.
4. **Teardown** (lever 3), measured.
   Measured: 0.24 ms for `print(1)` (about 5%), so skipping it is a small gain.
5. **Decide on lever 4** from fresh measurements, and record the decision.
   Measured: lexing and parsing the prelude are now about 1.6 ms of `print(1)`'s 5.1 ms,
   and resolving it about another 1.0 ms, so the prelude's front end is now the largest cost
   for small programs, larger than any remaining checker work. Doing it once when Emerald
   is built is the remaining big lever for them; it needs a design pass of its own.

## Risks

- **A reachability gap** would run a body the checker never saw. The panic makes it loud,
  and the conformance cases for each entry point make it unlikely; when unsure, reach more.
- **Prelude mistakes going unnoticed** in bodies no conformance case reaches, prevented by the
  whole-prelude check in `zig build test`.
- **Different diagnostics order or content** if checking order changes. The checker already
  sorts diagnostics into file order, but compare every `diagnostics/` expectation.
