# The compiler: design plan

Status: accepted by the user, 2026-11-06, every decision as recommended and questions A to D
answered as recommended; slice 0 is under way. Proposed the same day. Written when the user paused raylib to wait for the compiler
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
suite passes untouched, and the benchmarks do not get slower.

**Slice 2: the IR and the smallest compiler.** IR, lowering, the C emitter and `emerald build`
for `Int`, `Float`, `Bool`, functions, control flow, `print` and overflow; the build-tools
lookup and its message; `zig build test-compiler` with its first list of cases.

**Slice 3: values on the heap.** Strings, lists, dictionaries, sets, tuples, ranges, structs,
classes and closures, with reference counting, copy-on-write and the cycle collector.

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
- **B. Accepted: emit C, pending slice 0.** The route. Recommended: emit C (decision 1), confirmed or overturned by slice 0's
  numbers.
- **C. Accepted: `run` stays the interpreter for now.** Recommended: stays the interpreter; revisit after the whole suite
  passes compiled.
- **D. Accepted: erased first.** Generics. Recommended: erased first, monomorphized later as an optimization.
