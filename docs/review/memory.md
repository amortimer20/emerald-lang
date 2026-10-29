# Area 1: memory and lifetimes

Reviewed 2026-10-28/29 on `claude/review-memory`, branched from main at `d580f40`, with Zig 0.17.0
on macOS (aarch64, Darwin 27). Method: `codebase-review-plan.md`, section 4, row 1.

## Summary

**8 findings, all crashes or leaks, and all of them only when an allocation fails.** No program
leaks, double-frees, or crashes on a normal run, and no copy-on-write or reference-count probe
showed a value changing when it should not.

What was run, all through a Debug build of the CLI (`zig build`), whose `runtimeAllocator`
is `init.gpa`, a leak-checking `DebugAllocator`:

| Corpus | Programs | Command | Result |
| --- | --- | --- | --- |
| `conformance/run/` (files and projects) | 247 | `emerald run <case>` from `conformance/`, with `<case>.input` as stdin | clean |
| `conformance/runtime-errors/` | 81 | the same | clean |
| `conformance/color/`, `local-zone/` | 3 | the same | clean |
| `conformance/repl/` | 20 sessions | `emerald repl < <case>.input` | clean |
| `conformance/diagnostics/` | 420 | `emerald check <case>` | clean |
| `examples/` (files and projects) | 31 | `emerald run <example>` | clean |
| `benchmarks/` | 13 | `emerald run benchmarks/<name>.em` | 10 clean, output equal to `.expected`; `generics`, `json`, and `strings` did not finish (see the note below) |
| Probes of copying and counts | 12 | `emerald run`, `emerald test` | clean, correct answers |

"Clean" means no `leaked`, `Double free`, `panic`, segmentation fault, or `reached unreachable`
on standard error, and no hang (a 60-second limit per program, longer for benchmarks).

The four `conformance/http/` cases were not run through the CLI, since they need the suite's
local test server; the conformance suite already runs them under the testing allocator, 50 times
each.

**Allocation-failure injection.** `emerald.run` returns `error.OutOfMemory` rather than a
diagnostic, so `std.testing.checkAllAllocationFailures` would work in principle, but it stops at
the first failure and gives no index. The harness in `docs/review/repro/memory/oom/` instead
counts a program's allocations in a clean run, then reruns it with allocation *N* failing, for
every *N*, each on a fresh `DebugAllocator`, printing the index before each run. A crash ends
the process, so a wrapper restarted it at the next index (up to 60 crashes per program) to see
what lay behind the first. 40 conformance programs were sampled, covering every library
(Base64, Bytes, CSV, dates and durations, zones, digests, JSON, Math, paths, regular expressions,
strings, Unicode text, files) and language area (closures, classes, inheritance, traits, enums,
generics, optionals, tuples, errors, collections and their copies, tasks, channels, and
cancellation): 25 were clean at every index, 15 crashed or leaked at some. Programs over about
1,500 allocations were sampled at an even stride rather than at every index (`named-zones.em`,
for example).

Note on the benchmarks: the machine was shared with seven other review agents (load average
170 at one point). A Debug build runs the benchmarks very slowly, so `generics.em`, `json.em`, and
`strings.em` hit the 50-minute limit, and a rerun of the three was still running when the time box
ended. Nothing in what they printed was a leak or crash report, but a leak is reported only at
exit, so **these three are unchecked**. A rerun on an idle machine, or a ReleaseSafe build with a
leak-checking allocator, would settle them.

## How to run the harness

```sh
cd docs/review/repro/memory/oom
mise exec -- zig build                # builds zig-out/bin/oom against ../../../../../src
cd ../../../../..                     # back to the repository root
docs/review/repro/memory/oom/zig-out/bin/oom [--only N | --from N] <program.em>...
```

`--only N` fails allocation *N* alone. Without it, every index is tried. Allocation indices
below are for macOS on `d580f40`; they count from the start of `emerald.run`, so a source change
before the failing point moves them. Without `--only`, the harness finds the index itself.

## Findings, by severity

The common cause of findings 1 to 4: `Heap.createTuple` and `Heap.createStruct` take over their
`items`/`fields` slices on failure too (each frees them, and `createStruct` also releases the
values in them), but several callers keep an `errdefer` that releases or frees the same slices.
On a failed `gpa.create`, the slices are cleaned twice. `createTuple` frees `items` without
releasing the values in them, unlike `createStruct`, so the two contracts also disagree.

### 1. A tuple literal crashes when its tuple cannot be allocated (use after free)

- Reproduction: `docs/review/repro/memory/01-tuple-literal-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 62 docs/review/repro/memory/01-tuple-literal-oom.em`
- What happens: `Segmentation fault at address 0xaaaaaaaaaaaaab1a`, in `Heap.release`
  (`src/Heap.zig:790`) called from `evaluateTuple`'s `errdefer` (`src/Interpreter.zig:3461`).
  `createTuple` (`src/Heap.zig:483-486`) has already freed `items` and `kinds`; the `errdefer`
  reads the freed `items` (0xaa is Debug's freed-memory fill) and would free both again.
- Reach: the most common crash in the sample, 69 crashes in `csv-decode.em` alone, and in
  `tuples.em`, `date-basics.em`, `date-time-basics.em`, `generics-functions.em`, and
  `csv-encode.em`. Every tuple literal reaches it.
- Should: report the failure as out of memory and free each allocation once. Allocation failure
  is not language behavior (19.4: "Allocator choice stays out of Emerald's language
  semantics"), but the review plan, section 2, counts a crash under the testing allocator as a
  finding.

### 2. `String.partition` crashes the same way in `stringTuple`

- Reproduction: `docs/review/repro/memory/04-string-tuple-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 67 docs/review/repro/memory/04-string-tuple-oom.em`
- What happens: `Segmentation fault at address 0xaaaaaaaaaaaaab1a`, `src/Heap.zig:790` from
  `stringTuple` (`src/Interpreter.zig:11036`). Same cause as finding 1: the `errdefer` at
  11035-11039 cleans `items` and `kinds` after `createTuple` has freed them.
- Should: as finding 1.

### 3. A `CsvError` crashes when its struct cannot be allocated (use after free)

- Reproduction: `docs/review/repro/memory/03-csv-error-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 83 docs/review/repro/memory/03-csv-error-oom.em`
- What happens: `Segmentation fault at address 0xaaaaaaaaaaaaab1a`, `src/Heap.zig:790` from
  `makeCsvError`'s `errdefer` (`src/Interpreter.zig:6009`). `createStruct`
  (`src/Heap.zig:503-506`) has released and freed `fields`; the `errdefer` releases and frees
  them again. Seen in `csv-errors.em` and `csv-encode.em` too.
- Should: as finding 1.

### 4. `Json.decode` (and `Csv.decode`) into a struct double-frees its fields

- Reproduction: `docs/review/repro/memory/02-json-decode-struct-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 67 docs/review/repro/memory/02-json-decode-struct-oom.em`
- What happens: `error(DebugAllocator): Double free detected.`, allocated at
  `jsonDecodePlainStruct` (`src/Interpreter.zig:6627`), freed first in `createStruct`
  (`src/Heap.zig:506`) and again by the `catch` at `src/Interpreter.zig:6630`. Typed CSV decoding
  goes through the same function (`csv-decode.em`, 9 times).
- Should: free `fields` once.

### 5. `Json.parse` crashes when its builder's shared values cannot be allocated

- Reproduction: `docs/review/repro/memory/07-json-parse-builder-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 89 docs/review/repro/memory/07-json-parse-builder-oom.em`
- What happens: `Segmentation fault at address 0x30`, `src/Heap.zig:844` from
  `JsonBuilder.deinit` (`src/Interpreter.zig:6441`) run by `init`'s `errdefer` (6425). A
  different cause from findings 1 to 4: lines 6432-6433 write
  `builder.empty_items = .{ .data = .{ .list = try heap.createList(...) } }`. Zig's result
  location writes the `.list` tag into `builder.empty_items` before the `try` fails, so the
  field holds a `.list` with an undefined pointer, and `deinit` releases it. `empty_entries`
  (line 6433, `src/Heap.zig:816`) crashes the same way: 21 crashes each in `json-basics.em`.
- Should: assign through a local first, as the `kinds` loop above it (6427-6429) does.

### 6. `strings.characters` leaks its list when an append fails

- Reproduction: `docs/review/repro/memory/05-characters-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 65 docs/review/repro/memory/05-characters-oom.em`
- What happens: `error(DebugAllocator): memory address 0x... leaked`, allocated at
  `src/strings.zig:273` in `characters`, called from `base64Decode`
  (`src/Interpreter.zig:5289`). `characters` (270-275) has no `errdefer pieces.deinit(gpa)`.
  Also reached from `Bytes.from_hex` (`src/Interpreter.zig:10943`, 12 leaking indices in
  `bytes-hex.em`), `strings.reverse` (`src/strings.zig:384`), and `String.chars`
  (`src/Interpreter.zig:10874`).
- Should: free the list on failure, as `split`, `lines`, and `words` do.

### 7. `strings.split` leaks a piece when appending it fails

- Reproduction: `docs/review/repro/memory/08-split-piece-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 61 docs/review/repro/memory/08-split-piece-oom.em`
- What happens: `memory address 0x... leaked`, allocated at `src/strings.zig:243` in `split`
  from `stringMethod` (`src/Interpreter.zig:10859`). In
  `try pieces.append(gpa, try gpa.dupe(u8, ...))`, a successful `dupe` is lost when `append`
  fails: the `errdefer` frees only pieces already in the list. Line 246 has the same shape.
- Should: free the piece when appending it fails.

### 8. `List.partition` leaks when its second slice cannot be allocated

- Reproduction: `docs/review/repro/memory/06-partition-list-oom.em`
- Command: `docs/review/repro/memory/oom/zig-out/bin/oom --only 68 docs/review/repro/memory/06-partition-list-oom.em`
- What happens: `memory address 0x... leaked`, allocated at `src/Interpreter.zig:8670` in
  `callPartition`. Lines 8668-8676 build two lists, `items`, `kinds`, and the tuple with no
  cleanup between them, so `items` leaks when `kinds` fails. `kept` and `dropped` are heap
  objects, which `Heap.deinit` frees at the end, so they do not show as leaks, but they stay
  live for the rest of the run. And if `createTuple` itself fails, it frees `items` without
  releasing the two lists in it (the contract difference above).
- Should: release what was built when a later allocation fails.

## Checked and found clean

- **Every program on a normal run**, as in the table: no leak, double free, or crash in any
  conformance program, example, benchmark, REPL session, or `check` of a diagnostics case.
- **`emerald test`** on a probe with a passing test, a failed assertion, an uncaught index
  error, and an error raised inside a task with a channel holding a list: correct report
  (`4 tests, 3 failed.`), exit 3, no leak.
- **Copy-on-write** (10.1, 8.x): nested lists copied and then changed through an index
  (`copy[0].append`), a row taken out of a grid and changed, dictionaries of lists, lists of
  structs changed through `qs[0].xs.append`, a struct field of a class copied out and then
  changed on either side, a set put into a list and changed afterwards. Every original kept its
  value.
- **Closures** (7.4): a block changing a captured struct's list, leaving a `const` copy taken
  before it unchanged; a block keeping a snapshot of a list per loop iteration; a returned
  closure changing its own captured list across calls.
- **Channels** (15.13): a struct holding a dictionary of lists sent, then changed by the
  sender; a nested list sent, then changed; two tasks each copying and changing a list they were
  given. Every receiver saw the value as sent.
- **JSON, CSV, `Program.environment`, `Program.arguments`**: a decoded struct copied and then
  changed, decoded CSV rows copied and changed, an environment string extended, and the
  arguments list copied and appended to: the source values unchanged.
- **Cycles**: 2,000 self-referencing objects, each with a closure capturing itself, plus a
  two-object cycle: no leak at exit, correct output.
- **Values in flight at abnormal ends**: `exit` from a task while a channel holds lists and
  another task sleeps; an uncaught error with a channel holding objects; a `DeadlockError`
  with sends pending; an uncaught error with a file writer and reader left open. All clean.
- **Allocation failure, clean at every index** (25 programs): `channel-values`, `channel-fifo`,
  `closures`, `collection-mutation-copies`, `errors`, `dictionaries`, `file-streaming`,
  `list-sort`, `math`, `optionals`, `enum-data`, `sets`, `struct-methods`, `task-results`,
  `task-cancellation`, `inheritance`, `unicode-text`, `path`, `classes`, `traits`, `digest`,
  `regex-errors`, `regex-basics`, `regex-replace-split`, `duration-basics`.
- **Heap objects are not checked by the harness.** Objects made by `Heap.create*` are linked
  into the heap's live lists and freed by `Heap.deinit` at the end of a run, so an object whose
  count is never dropped does not show as a leak, only raw `gpa` allocations do. A heap-object
  leak would need the heap's live count checked before `deinit`; this review did not do that.
