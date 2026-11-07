# The compiler: design plan

Status: accepted by the user, 2026-11-06, every decision as recommended and questions A to D
answered as recommended. Slice 0 (the prototypes) has run; its report is below. It confirms
decision 1 (emit C) and question A (a separate build-tools archive), and slice 1 is next. Proposed the same day. Written when the user paused raylib to wait for the compiler
("I'm ready to get going on it"). This is
roadmap item 12 (handoff): **choose the backend by prototype, then build the compiler, in Zig,
for 1.0.** It gathers what the handoff's "Longer term: the native compiler" section already
settled, adds the decisions that section left open, and orders the work into slices.

The executor makes the remaining judgement calls within a slice and records each under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## Already settled (do not reopen)

From the handoff, decided by the user:
- **Zig, for good** (2026-10-11). The compiler is written in Zig, in this repository, on the
  front end the interpreter already uses. The runtime of a compiled program is Zig too.
- **No rewrite and no differential run.** Interpreter and compiler share the lexer, parser,
  resolver and checker. The compiler is accepted when it passes `conformance/` unchanged
  (spec 19.6, 23).
- **The interpreter stays**: the REPL, the playground's engine, and the fallback where no
  toolchain is available.
- **Runtime error text is part of the language**, and a compiler shares the interpreter's
  message-building code rather than copying it (2026-10-29, review item D2).
- **The prototypes answer, in order:** can it reach Godot (GDExtension is a C ABI), can it make
  microcontroller firmware (Raspberry Pi Pico), can it reach WebAssembly.
- **Emitted code keeps every runtime check** the language requires (index, overflow, optional).
- **Godot bindings, microcontrollers and multicore come after 1.0** (items 14 and 15); the
  compiler only has to keep the doors open.
- **raylib waits for the compiler** (2026-11-06): the vendor-library mechanism is merged, and
  slice 2 of that plan resumes once compiled programs can call a module.

## What exists to build on (2026-11-06)

- **Front end**, about 26,000 lines: `Lexer.zig`, `Parser.zig` (6,100), `Resolver.zig`
  (3,600), `Checker.zig` (14,400), `Type.zig`. The checker's results are keyed by syntax-tree
  node, which the handoff lists as a thing a compiler must replace or wrap.
- **Interpreter**, `Interpreter.zig` (11,800 lines), a tree walker. Natives are found by string
  key (`Console::_color` and the rest); slice 1 of the vendor plan added a per-call-site cache
  for vendor natives only.
- **Runtime pieces the interpreter owns today:** `Heap.zig` (reference counts for prompt
  freeing and copy-on-write value semantics, plus a mark-and-sweep collector for cycles),
  `Value.zig`, `Scheduler.zig` (tasks as OS threads passing a baton), and the library code
  (`strings`, `unicode`, `Json`, `Regex`, `Csv`, `Http`, `TimeZone`, `FloatMath`).
- **The prelude,** `src/prelude.em` (2,500 lines of Emerald), parsed when Emerald is built.
- **Generics are erased** in the interpreter; the generics plan says the language promises
  nothing a compiler could not do either way.
- **The contract:** 283 `run/` and 88 `runtime-errors/` conformance cases, plus 533
  `diagnostics/` cases that the shared front end already answers.
- **Speed baseline:** `benchmarks/` holds 13 programs at 0.3 to 0.6 seconds each, startup
  included (`baseline.md`, Apple A18 Pro).
- **Sizes measured for this plan:** the 0.8.0 downloads are 2.3 to 2.4 MB (Windows, macOS) and
  7.0 MB (Linux). The Zig 0.17.0 toolchain on this Windows machine is 399 MB unpacked, of which
  `zig.exe` (which carries clang and LLVM) is 190 MB.

## What the compiler must do

1. `emerald build program.em` produces one native executable for Windows, macOS or Linux that
   behaves exactly as `emerald run program.em` does: the same output, the same runtime error
   text, the same exit codes.
2. Cross-compiling with `--target` (one machine builds for the other two), since Zig makes it
   nearly free.
3. Faster than the interpreter by a margin that matters for games, the reason raylib waited:
   a recommended target of **ten times** on `fib` and `nbody`, measured by `benchmarks/`.
4. Errors in a compiled program still point at Emerald source lines, not generated code.
5. Doors left open, proven by slice 0, not built: a shared library with a C ABI (Godot), a
   32-bit ARM build with no operating system (Pico), and WebAssembly.

## Decisions

Each carries a recommendation; the alternatives are kept for the record.

1. **The route: emit C and compile it with Zig's bundled clang (recommended, to be confirmed
   by slice 0).** The candidates from the handoff:
   - **Emit C, compile with `zig cc`.** C is a stable target that does not move with Zig
     upgrades; clang compiles it quickly; `#line` directives map every generated line back to
     the `.em` line, so debuggers and crash reports show Emerald source; every target Zig
     reaches (Pico, WebAssembly, a Godot-loadable shared library) is reached the same way.
     The runtime stays Zig, built once per target as a static library with a C ABI.
   - **Emit Zig source.** Readable, and one language end to end, but every Zig upgrade (item 8)
     can break the generated code as well as the runtime, and Zig compiles more slowly than
     clang compiles C, which a student feels on every build.
   - **A bytecode VM in the runtime.** No toolchain on the user's machine, but slower, likely
     two to five times faster than the tree walker, not ten. It is still the right shape for
     the Pico's on-board REPL later (handoff), and decision 2 keeps it as the fallback.
   - **LLVM directly.** Ties Emerald to LLVM's changing interface; Zig's own backends are not a
     stable library. Set aside.

2. **The toolchain is a separate, optional download, versioned with Emerald (recommended;
   question A).** A C route needs clang and a linker on the user's machine. Bundling Zig in
   every download would grow a 2.4 MB archive by something like a hundred megabytes (slice 0
   measures it compressed), for students who may never build. So: `emerald` stays as it is,
   and **Emerald build tools** is a second archive per platform holding the pinned Zig, placed
   beside `emerald` by the install scripts when asked (`--with-build-tools`), or unpacked by
   hand on a school machine with no network. `emerald build` without it stops with a message
   saying how to add it. Alternatives: bundle it always (simplest, heaviest); fetch it on first
   use (breaks "a school machine needs no network"); write our own machine-code generator (years
   of work for three architectures plus WebAssembly). A **bytecode fallback**, where `emerald
   build` without the tools packs the program's bytecode with a prebuilt VM into an executable,
   is a later option, not part of 1.0.

3. **Lower the checked tree to an Emerald IR, then emit (recommended).** The handoff's
   recommendation: a small intermediate form with explicit control flow, explicit
   reference-count operations, and explicit runtime checks, produced from the checker's typed
   tree. The emitter only translates IR to C, so a second emitter (bytecode, WebAssembly
   directly) reuses everything above it. Optimizations that only Emerald knows go here, later:
   cancelling retain and release pairs, skipping copy-on-write copies that cannot happen.
   1.0 needs correctness, not those optimizations. Alternative: emit C straight from the tree,
   faster to start and harder to optimize or to retarget.

4. **One runtime, shared with the interpreter (recommended).** The heap, values, strings,
   Unicode, collections, the library code and the error messages move out of the interpreter
   into a runtime layer both engines call. The interpreter keeps walking trees; the compiled
   program calls the same functions through a C ABI. This is what makes "the same output, the
   same error text" true by construction rather than by testing, and it is the D2 decision
   applied. Natives get stable numeric ids in place of string keys, a table both engines use.
   Alternative: a second runtime written for the compiler, which doubles every library and
   every message.

5. **Values in compiled code are unboxed where the type is known (recommended).** `Int`,
   `Float` and `Bool` locals are C `int64_t`, `double` and `bool`; overflow uses clang's checked
   builtins and raises the same `RuntimeError`. Strings, lists, dictionaries, structs, classes
   and closures are pointers into the shared heap with the interpreter's reference counting and
   copy-on-write rules. An optional is a tag plus the value.

6. **Generics are erased first (recommended; question D).** A generic function compiles once
   and works on a uniform boxed value, as the interpreter's does, which keeps code small and the
   compiler simple. Copying a generic body per type (monomorphizing), which is faster, is a
   later optimization that changes no program, since the generics plan promises nothing either
   way. Alternative: monomorphize from the start.

7. **Errors travel as return values (recommended).** Every call that can raise returns a
   status the caller checks, and `try` and `catch` become ordinary branches, so reference counts
   are released on the way out and nothing depends on `setjmp`, which would skip those releases
   and does not exist on every target. The cost is one predictable branch per fallible call.

8. **Tasks use the same scheduler (recommended).** Compiled programs run tasks on the runtime's
   `Scheduler` exactly as the interpreter does (OS threads passing a baton), so `Tasks.run`,
   channels and deadlock detection behave identically. Multicore stays after 1.0.

9. **The prelude is compiled into the runtime (recommended).** Its Emerald bodies go through
   the same compiler when Emerald's runtime is built for each target, so a compiled program
   links them, and never parses `prelude.em`.

10. **The command line (recommended; question C).** `emerald build program.em` writes
    `program` (or `program.exe`) beside it; `-o` names it, `--target` cross-compiles, `--debug`
    keeps runtime assertions and full debug information (the default is an optimized build with
    every language check kept). `emerald run` stays the interpreter. Whether `run` later uses the
    compiler when the tools are present is decided once the compiler passes the whole suite.

11. **The suite gains a compiled mode (recommended).** `zig build test-compiler` compiles each
    `run/` and `runtime-errors/` case and compares its output with the same `.expected` file.
    While the compiler is incomplete, a list of cases it must pass grows slice by slice, and
    the list is deleted when it holds every case. `benchmarks/` gains a compiled column.

12. **Vendor modules are linked statically into compiled programs (recommended; from the
    vendor plan's decision 2).** The module's `emerald_module` table is the same; the compiled
    program links the module's static library instead of loading it, so a raylib game builds to
    one executable.

## Slices

Each slice is a branch and a PR: one commit per change, `/code-review` at high effort, handoff
and journal updated, the user merges.

**Slice 0: prototypes, no merge.** On a branch: hand-lower three programs (`fib`, `nbody`, and a
string-and-list one such as `words`) to C and to Zig against a stub runtime written in Zig;
measure compile time, run time and binary size for each route; build the C one for
`wasm32-wasi`, for a bare `thumbv6m` (Pico) target, and as a shared library whose exported
C function another program loads (the Godot question); measure the build-tools archive
compressed per platform, and what can be left out of Zig's distribution. Deliverable: a report
appended here, a go or no-go on decision 1's route, and a measured answer for question A.

**Slice 1: the runtime layer.** Move the heap, values, library code and messages behind the
runtime boundary of decision 4, and give natives numeric ids. No behaviour change: the whole
suite passes untouched, and the benchmarks do not get slower. *As built:* a method dispatched on
its receiver's kind (strings, lists, dictionaries and the rest) has an id in `Natives.Id`; a
prelude native is a runtime function a compiled program calls by name, and a family with many
entries (Regex, Math) also gives an enum of them. Files, Http, `print`, `input`, `exit`,
`sleep` and `Console.clear` move in slice 6 (see 1b part 2 below).

*Settled while building (2026-11-06):* slice 1 is three PRs, merged in order, because the
interpreter's natives read their arguments from the syntax tree (about 150 dispatch sites
compared by string) and 269 raise sites build their messages inside `Interpreter.zig`; one PR
would be too large to review.
- **1a, the boundary.** The runtime files move to `src/runtime/` and build as their own Zig
  module, `runtime`, which imports nothing from the front end or the interpreter, so a compiled
  program can link it alone. The one front-end tie, a closure's pointer to its lambda's syntax
  tree, becomes an opaque pointer only the interpreter interprets.
- **1b, natives.** Each native gets a numeric id in one table and an implementation that takes
  evaluated values and gives a value, in the runtime; the interpreter resolves a call site's id
  once and evaluates the arguments itself. Each native's messages move with it.
  1a done on `claude/runtime-layer`: thirteen files and the Unicode and time-zone data moved;
  `src/runtime/runtime.zig` is the module's root and `runtime-test` runs its 149 tests on its
  own; benchmarks unchanged (0.95 to 1.04 of before, noise). The boundary is so far one of
  imports: the runtime still carries interpreter-shaped types (`Environment`, closures that name
  their function by key or hold an interpreter's lambda as an opaque pointer, the REPL's
  `session_entry` fields). Slice 3, which gives compiled programs closures and structs on this
  heap, replaces the opaque `lambda` with a variant per engine so no engine reads another's
  code pointer, and decides what of the rest a compiled program needs.
  1b is two PRs. **1b part 1** (`claude/runtime-natives`): `runtime/Native.zig` (the
  `Context` a native runs in, its recorded `Failure`, and `Engine` callbacks for a type's own
  `equals()`, `hash()` and `compare()` and for randomness), the methods on strings, bytes,
  `Int`, `Float`, ranges, lists and dictionaries with their messages (about 1,300 lines out of
  `Interpreter.zig`), and `runtime/Natives.zig`, the table of ids (`Natives.Id`, `lookup`,
  `call`). A failure that names an argument keeps its location: the interpreter passes the span
  the old code reported at (for a dictionary method, its first argument's). That choice lives at
  the interpreter's call site, so before a compiled program calls these natives (slice 3) a
  `Failure` should say which argument it is about, and both engines report there. Benchmarks
  0.87 to 1.05 of 1a's (noise, slightly faster).
  **1b part 2** moves the prelude's natives (Regex, Json and Csv without a target type, Base64,
  Digest, Math, time zones, Console, files, Http, the clocks and the environment). They need
  runtime state the interpreter owns today, so it adds a `Native.State` (the regex cache, the
  I/O handle, the terminal's settings) and an `Engine` callback for the prelude's struct types,
  such as `Regex::Match`. Natives that run blocks, change their receiver in place, decode to a
  type the checker named, or start tasks stay in the interpreter until the slices that compile
  those features (3, 5 and 6).
  1b part 2 done on `claude/prelude-natives`: `RegexNatives`, `EncodingNatives` (Base64, hex,
  the digests), `TimeNatives`, `JsonNatives` and `CsvNatives` (without a target type),
  `MathNatives` and `SystemNatives` (Console's width and plain text, the clocks, the
  environment). `Native.State` holds the regex cache, the machine's zone, the zone database and
  its cache; the context carries `io`; `Engine.prelude_struct` gives the prelude's struct types;
  a native can raise an error value it built itself (`raiseValue`, for `CsvError`'s `line`).
  `Interpreter.zig` is 9,700 lines. *Settled while building:* files and Http stay in the
  interpreter for now, as do `print`, `input`, `exit`, `sleep` and `Console.clear`. They release
  the task baton around blocking I/O, check for cancellation, lock file handles shared between
  tasks, and `File.with_open` runs a block, so they need an engine interface for blocking and
  cancellation that belongs with slice 6 (the library and tasks), which moves them. A builder that
  holds a native's context must not outlive the call: `JsonNatives.buildValue` builds a whole
  value inside one call for that reason.
- **1c, the remaining messages.** The runtime errors the interpreter raises for operators,
  indexing, overflow, optionals and conversions get their text from runtime functions both
  engines call.
  1c done on `claude/runtime-messages`: `runtime/Operations.zig` holds `Int` and `Float`
  arithmetic with overflow and division by zero, negation, `not`, comparison, indexing a list,
  String or Bytes, slice bounds, a missing dictionary entry, a Range too large to count, a name
  read before it is assigned, and too much recursion; `Bytes.from_list`'s byte check joined
  `BytesMethods`. `Ast.BinaryOperator` is now the runtime's `Operations.Arithmetic`, so the
  checker and both engines name an operator the same way. `Interpreter.zig` is 9,400 lines.
  *Settled while building:* optionals raise nothing at run time (the checker forces `.or` or a
  check), and the conversions (`to_int`, `to_float` and the rest) raise from the string and
  number natives that 1b moved, so neither had messages left to move. Each engine does the common case inline (`Int` `+`, `-` and `*`, an index
  in range) and calls these functions for the rest; the interpreter calls them through
  `runNativeCold`, which is never inlined, because inlining a native's context into the hot
  functions slowed `sieve` and `nbody` by up to 15 percent. Benchmarks 0.96 to 1.00 of main.

**Slice 2: the IR and the smallest compiler.** IR, lowering, the C emitter and `emerald build`
for `Int`, `Float`, `Bool`, functions, control flow, `print` and overflow; the build-tools
lookup and its message; `zig build test-compiler` with its first list of cases.
*As built* on `claude/compiler-smallest`: `src/compiler/Ir.zig` (basic blocks, a check
instruction for each runtime check, carrying the site its failure reports), `Lower.zig`,
`EmitC.zig` and `Compiler.zig`; `src/runtime/compiled.zig` and `emerald.h`, the runtime's C
interface, built by `zig build` as a static library under
`zig-out/build-tools/runtime/<arch-os-abi>/`; and `emerald build [--debug] [-o <output>]
<file.em>`. It compiles `Int`, `Float` and `Bool` values, functions of them, `if`, `while`,
`for` over a written range, `break`, `continue`, `and`, `or`, `not`, comparison chains, and
`print` and `write` with literal and interpolated text. Anything else stops the build with
"`emerald build` cannot compile ... yet" at the construct, before the build tools are needed.
`conformance/compiled.txt` holds the 27 cases that build and match exactly (21 `run/`, 6
`runtime-errors/`), and CI runs `zig build test-compiler` on all three systems. Of every
single-file case tried, none built and behaved differently. Compiled `fib` runs in 0.009 s,
63 times the interpreter's 0.58 s, and builds in 0.6 s.
*Settled while building:*
- **The build tools' layout.** `build-tools/zig/zig[.exe]` and
  `build-tools/runtime/<arch-os-abi>/` holding the runtime library, looked for in
  `EMERALD_BUILD_TOOLS`, then beside the executable, then beside its directory, as library
  modules are. `EMERALD_ZIG` names another Zig, which is how the tests use the build's own.
  `emerald.h` is compiled into `emerald` and written beside the generated C, so the header
  always matches the compiler. Slice 7's archive fills `zig/` and one runtime per target.
- **Failures and traces.** A failure records its message through `Operations` and returns
  status 1; each caller adds its frame to the trace and returns 1 in turn, so a call that
  succeeds costs one branch. The location, the quoted line and the carets are rendered at build
  time by `Diagnostic`, from the source the program was built from, and stored as constants.
- **Evaluation order.** A module variable read in an expression is copied first, since a call
  later in the expression can change it; `print` evaluates every argument before writing, as
  the interpreter builds the line first.
- **The common case stays inline** in the C (`+`, `-`, `*` with clang's overflow builtins,
  float `/`, `//` and `%` with a nonzero divisor), and the runtime does the rest: `**`, the
  float `//`, `%` and `**`, exact `Int` and `Float` comparison, and every failure.
- **Not yet:** `--target` (one runtime library per target is slice 7's), the call-depth limit
  and `RecursionError` (slice 4, with the other errors), and projects of several files (slice
  3, which needs the namespaced names).

**Slice 3: values on the heap.** Strings, lists, dictionaries, sets, tuples, ranges, structs,
classes and closures, with reference counting, copy-on-write and the cycle collector.
*Settled while building:* slice 3 is several PRs, as slice 1 was: **3a** strings, **3b** lists,
ranges and `for` over a collection, **3c** dictionaries, sets and tuples, **3d** structs and
classes, **3e** closures and blocks, and projects of several files where the work reaches them.
3a done on `claude/compiler-strings`: a `String` in generated C is the runtime's own
`Heap.Text`. The ownership rule, which every later part keeps: each local and global of a heap
type owns one reference or holds nothing; storing retains the new value and releases the old; a
function retains its heap parameters on entry and releases all its locals at its one exit, which
every return and every failure passes; an operation's result is a new reference its destination
takes over. Literals are the runtime's uncounted literal texts, made once each. Lowering compiles
literals and interpolations as values, `+`, the comparisons, `count`, indexing, slicing, every
method `Natives.zig` answers on strings and numbers (through `em_native`, with values tagged in
`Value.Kind`'s order and the result widened to the checker's type), and `to_string` on scalars.
After 1,000 iterations of joining, slicing and calling, the live heap held only the literals and
the global it should. `compiled.txt` grows from 27 to 43 cases, and of every single-file case
tried, none builds and behaves differently.

**Slice 4: errors.** `raise`, `try`, `catch`, error types, and the runtime errors with the
shared messages; the `runtime-errors/` cases join the list.

**Slice 5: enums, traits and generics.** Enums with data and `case`, traits, and erased
generics.

**Slice 6: the library and tasks.** The compiled prelude, every native, tasks and channels.

**Slice 7: the whole suite and the release.** The list of cases holds every case and is
deleted; the build-tools archives join the release workflow with checksums; the install scripts
learn `--with-build-tools`; docs and the website's pages for `emerald build`; the benchmarks'
compiled column, against the ten-times target.

**Then:** raylib's slice 2, with modules linked statically (decision 12), and Emerald 1.0
(item 13).

## Slice 0 report (2026-11-06)

The spike is the branch `claude/compiler-spike` (not for merge; `spike/compiler/`). It
hand-lowers three benchmarks, `fib` (calls and checked `Int` arithmetic), `nbody` (`Float`s
and structs in a list) and `words` (strings, lists, a dictionary, a seeded `Random`, and a
block passed to a sort), twice: to C the way decision 1's emitter would write it (unboxed
scalars, `__builtin_*_overflow`, a status return on every call that can raise, `#line`
directives), and to Zig. Both call one stub runtime written in Zig (`rt.zig`): reference
counts with copy-on-write, a tagged value for erased positions, the interpreter's `Random`
algorithm and `FloatMath.roundTo`, and natives with a C ABI. Every build printed exactly the
benchmark's `.expected` text. Measured on this Windows machine (16 cores), runtime ReleaseFast,
C at `-O2`, interpreter ReleaseSafe as released; times are the median of five runs, process
start included.

**Speed.**

| Program | Interpreter | C | Zig | C speed-up |
| --- | --- | --- | --- | --- |
| `fib` | 0.597s | 0.018s | 0.018s | 34x |
| `nbody` | 0.999s | 0.019s | 0.018s | 52x |
| `words` | 0.794s | 0.088s | 0.086s | 9x |

The two routes run at the same speed, as expected: both reach LLVM. The ten-times target is
met on `fib` and `nbody` with a wide margin, even though `nbody`'s structs sit on the shared
heap as erased values and every field write goes through copy-on-write checks (decision 4 as
written, with no layout optimization). `words` is at nine times because its time is in the
runtime (joining, splitting, hashing, sorting), which compiling the program does not touch; a
faster runtime helps both engines.

**Build time.** This is where the routes differ:

| | C | Zig |
| --- | --- | --- |
| First build on a new machine (empty cache) | 38 to 41 s | 50 to 51 s |
| Each build after that | 0.35 s | 11.5 to 12.2 s |

A Zig emitter recompiles the generated program with the runtime source through Zig's compiler
every time; the C route compiles only the generated file and links a runtime built once. So
**decision 1 stands: emit C.** The first build's time is Zig building the C library for the
target (mingw on Windows) into its cache; the build-tools archive can carry that cache already
built per host, a size question for slice 7.

**Size.** Each executable is about 930 KB on Windows, almost all of it the C library and the
runtime, identical for both routes. Not tuned: no stripping and no section garbage collection.

**WebAssembly.** The C route built all three for `wasm32-wasi` with the same runtime built for
that target (one change: the runtime's value-to-pointer cast must narrow on 32-bit targets),
and all three ran correctly under Node's WASI. The files are 1.5 to 1.7 MB unstripped.

**Pico.** All three built and linked for a Cortex-M0+ with no operating system
(`thumb-freestanding-eabi`, `-mcpu=cortex_m0plus`), with the runtime given a fixed 96 KB heap
and an output hook the board code supplies, and math from Zig's compiler runtime (no
floating-point hardware). Each is about 50 KB of flash, inside the RP2040's 2 MB; static RAM is
160 KB, of which 96 KB is the heap and 64 KB the runtime's output buffer, which a board build
would shrink, against the RP2040's 264 KB. Not done: running it. A real image also needs the
RP2040's boot stage and vector table, and nothing here was run on a board or an emulator.

**Godot.** Generated C built as a shared library (`-shared`) exporting an entry function and a
compiled Emerald function with a status result; a host program (Python's `ctypes`, standing in
for Godot) loaded it, called the entry, and got `fib(40)` back correctly. Godot itself was not
tried; GDExtension's binding layer is the post-1.0 work of roadmap item 15.

**The build-tools archive (question A).** The Zig 0.17.0 distribution for Windows is 399 MB
unpacked. Removing what a C build never needs (C++ libraries, the thread sanitizer, docs, and
the BSD C libraries) leaves 338 MB, which still built and linked for Windows, Linux, macOS and
WebAssembly. Compressed: **85 MB as a zip, 52 MB as `.tar.xz`**. Most of it is `zig.exe`
itself (190 MB, carrying clang and LLVM), which cannot be trimmed. That is twenty to forty
times the 2.4 MB `emerald` download, so the separate optional archive question A chose is
confirmed. Not measured: the macOS and Linux distributions, which slice 7 measures when it
builds the archives.

**Learned for the slices.**
- Status returns cost nothing measurable: `fib` checks one after every call and runs 34 times
  faster than the interpreter.
- Closures across the runtime boundary are a C function pointer plus an environment pointer,
  and the runtime calls back into generated code (`sort_by`). Decision 3's "no callbacks from C
  into Emerald" for vendor modules does not constrain the compiler's own runtime.
- A runtime built for one target is a static library of about 2.9 MB (Windows, with debug
  information) or 60 KB (Cortex-M0+, ReleaseSmall); the build-tools archive carries one per
  target it supports.
- The runtime's 64-bit value word must be narrowed to a pointer on 32-bit targets (WebAssembly,
  ARM), and its allocator and output must be swappable for a board.

**What the spike did not settle.** How much the shared runtime of slice 1 costs compared with
this stub (it carries the interpreter's full `Value` and `Heap`, which is heavier); compile
times for a real program of a few thousand lines; debugger experience through `#line`; macOS
and Linux timings (the spike ran on Windows only); and anything about Godot or a board beyond
building and loading.

## Validation

- Each slice: `zig build test -j1`, `zig build test-compiler` on its list, the doc-example
  check, and the benchmarks for any slice that touches the runtime.
- Slice 1 additionally: the benchmarks before and after, on one machine.
- Slice 7: the whole suite compiled on all three systems in CI, and one cross-compiled build per
  pair of systems run on the other.

## Out of scope for 1.0

Godot bindings, microcontroller targets and the on-board VM, WebAssembly as a shipped target,
multicore, monomorphized generics and the IR optimizations, a debugger (item 16), and a
bytecode fallback for machines without build tools. Slice 0 proves the first three are
reachable; it does not ship them.

## Questions for the user

- **A. Accepted: a separate, optional build-tools archive.** Where the C toolchain comes from. Recommended: a separate, optional "Emerald build
  tools" archive holding the pinned Zig (decision 2), so the 2.4 MB download stays small.
  Alternatives: bundle it in every download, or fetch it on first use.
- **B. Accepted: emit C, confirmed by slice 0.** The route. Recommended: emit C (decision 1), confirmed or overturned by slice 0's
  numbers.
- **C. Accepted: `run` stays the interpreter for now.** Recommended: stays the interpreter; revisit after the whole suite
  passes compiled.
- **D. Accepted: erased first.** Generics. Recommended: erased first, monomorphized later as an optimization.
