# Startup performance: design and implementation plan

Status: proposed, 2026-09-28, awaiting the user's go-ahead. The measurements below were
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

- **Add `tools/startup-benchmark.py`** (slice 1): runs a built binary on a few programs
  (`print(1)`, `examples/json.em`, and a program using dates and regular expressions),
  reporting the median wall time over 60 runs, user and system time, and page faults, with
  the machine noted. Use it before and after every slice, and record the numbers in the
  journal.
- **Stage timing** used temporary marks around each stage in `emerald.analyze` and each
  phase in `Checker.check`, printing elapsed time and `getrusage` page faults. Do not commit
  them; add them locally to find where a slice's time goes.
- **Build with `-j1`** on this 7 GB machine when another build may be running; parallel
  builds have run it out of memory.

## Slices

1. **The benchmark tool and baseline.** `tools/startup-benchmark.py`, and the baseline
   recorded in the journal.
2. **Reachable prelude bodies** (lever 1), with both safety nets, conformance showing a
   program reaching dates, regular expressions, JSON, HTTP, and a trait default, and the
   benchmark before and after.
3. **Fewer allocations while checking** (lever 2), guided by a counting allocator, with the
   largest sources recorded in the journal and the benchmark before and after.
4. **Teardown** (lever 3), measured.
5. **Decide on lever 4** from fresh measurements, and record the decision.

## Risks

- **A reachability gap** would run a body the checker never saw. The panic makes it loud,
  and the conformance cases for each entry point make it unlikely; when unsure, reach more.
- **Prelude mistakes going unnoticed** in bodies no conformance case reaches, prevented by the
  whole-prelude check in `zig build test`.
- **Different diagnostics order or content** if checking order changes. The checker already
  sorts diagnostics into file order, but compare every `diagnostics/` expectation.
