# Zig 0.17 upgrade: plan

Status: accepted by the user, 2026-10-28 ("Accept, start branch"), and built on
`claude/zig-0.17` against 0.17.0; "Settled while building" at the end records what the port
needed. Roadmap item 8, with item 9 (confirming the Windows stall is gone) folded in.

Zig is Emerald's permanent implementation language (2026-10-11), so this is routine maintenance,
but it is the largest mechanical change the codebase has had: about 300 call sites, the build
script, and the release pipeline. The plan keeps the change mechanical, proves it with the suites
Emerald already has, and adds one measurement the earlier upgrades lacked: the benchmark suite.

## Decisions at a glance

| # | Decision | Recommendation |
| --- | --- | --- |
| 1 | Which release | Build and test on 0.17.0 now, on a branch; merge when 0.17.1 ships, unless 0.17.0's `Run`-step regression does not touch Emerald's build |
| 2 | Macs | **Settled by the user, 2026-10-28:** Intel Macs are not supported. Releases are Apple silicon only, as today, and need macOS 15 or later, 0.17's minimum |
| 3 | Order | One branch, in four commits: the pin, the build script, the source, then CI and release |
| 4 | Proof | Every existing gate, the Windows suite in parallel repeatedly, and the benchmarks compared before and after |
| 5 | Out of scope | No refactoring beyond what 0.17 requires; no new language or library work on the branch |

## 1. Which release

0.17.0 came out on 2026-10-01; 0.17.1 is not out (checked 2026-10-28). The roadmap waits for
0.17.1 because 0.17.0 has known regressions, one in `Run` steps, which `build.zig` uses heavily
(the conformance suite, the Unicode and JSON checks, the REPL and scheduler benchmarks).

Recommendation: do the work now against 0.17.0 on `claude/zig-0.17`, and find out whether the
regression actually bites Emerald's build. If the whole gate passes on 0.17.0, the branch can
merge on the user's word without waiting. If it does not, the branch waits, and the switch to
0.17.1 is a one-line change to the pin. Either way the slow part of the work is done early, and
0.17.0's `process_spawn_mutex` lets CI drop the Windows `-j1` workaround (item 9).

## 2. Macs

The user's decision (2026-10-28): Intel Macs are not supported. Today's releases are already
`linux-x86_64`, `macos-arm64`, and `windows-x86_64`, and `install.sh` already refuses an Intel Mac
with a plain message, so nothing is taken away. What changes is that it becomes a stated
policy, and that 0.17 raises the macOS minimum to 15:

- Every Apple silicon Mac can run macOS 15, so no Apple silicon Mac is left out; one running an
  older macOS needs updating first.
- `install.sh` gains a version check: on macOS before 15 it says so and stops, rather than
  installing a binary that will not start.
- The README, the website's install instructions, and the notes of the release that ships it say
  "Apple silicon, macOS 15 or later". rewrite-context records the supported platforms.

## 3. The work, in order

All on one branch, `claude/zig-0.17`, so main never holds a half-upgraded build.

1. **The pin.** `mise.toml` and `toolchain/zig-version.txt` move to the new version;
   `tools/check-toolchain.sh` follows. `.github/copilot-instructions.md` and the docs that name
   0.16.0 are updated.
2. **The build script.** `build.zig` moves to 0.17's configure-and-make split:
   `addPassthruArgs()` for the four `b.args` forwards, the `Fmt` step's paths, and every
   `-Doptimize=ReleaseSafe` that now spells its mode differently. 0.17 renames the optimize modes
   (`debug`, `safe`, `fast`, `small`), so every place that passes `ReleaseSafe` changes with it.
   Today that is the CI and release workflows, the fuzz workflow, about a dozen scripts in
   `tools/`, `tools/benchmark.py`'s instructions, and the docs.
3. **The source**, counted on main at `1afc106` (2026-10-28):
   - 275 `allocPrint` calls, which become `Allocator.print()`: mechanical, done with a script and
     reviewed as one diff.
   - 11 `@bitCast` uses, each reviewed by hand. 0.17's `@bitCast` reinterprets logical bits, which
     is the one change that can alter behavior silently. Most are the seeded `Random` state and
     float bit patterns, both covered by conformance cases with fixed output.
   - 30 deprecated `@intFromEnum` and `@enumFromInt` uses, 4 `std.meta.field*` uses, and one
     `errdefer` capture.
   - Whatever else the compiler reports. Each fix is the smallest one 0.17 accepts.
4. **CI and release.** Both Windows jobs drop `-j1` (item 9). The release workflow builds the
   three platforms with the new mode name. `release.yml` runs a dry build on the branch before
   merge so the first real release is not its first run.

## 4. Proof

The upgrade is done when all of these pass, with numbers recorded in the journal:

- **Every existing gate** on all six CI jobs: `zig build test` in both modes, cancellation with
  live input, the fuzz campaign, and the Windows task measurements.
- **The Unicode and JSON conformance tools** against their full downloads, since they run as
  `Run` steps.
- **The Windows stall is gone (item 9).** The parallel Windows Debug and ReleaseSafe suites run
  without `-j1`, 20 times each through `workflow_dispatch`, with no "failed to respond". If one
  stalls, the flags go back and the cause is investigated anew.
- **The benchmarks** (`tools/benchmark.py`), on the same machine: a ReleaseSafe build of main
  before the upgrade against one after, two binaries alternating. A program more than 10% slower
  is explained before merge, not waved through. A faster one is noted, not claimed: a new
  compiler can move timings either way.
- **The release pipeline**, as a dry build of all three assets, and `install.sh` and
  `install.ps1` run against those assets on each platform.
- **The editor**: the language server's tests pass, and the VS Code extension, which runs the
  `emerald` binary, is tried by hand against the new build.

## 5. Out of scope

- Refactoring the code 0.17 makes possible (new `std` APIs, the configure-and-make split beyond
  what the build needs). Each is its own later change, if it earns one.
- The WebAssembly playground (item 6), even though 0.17's WebAssembly backend helps it. It is
  easier to start once the upgrade has merged.
- Any language or library work. The branch changes how Emerald is built, never what it does, and
  the conformance suite's unchanged expected output is the proof.

## Risks

- **`@bitCast`'s new meaning** could change seeded random numbers or float handling without a
  compile error. Mitigation: review all 11 by hand, and the conformance cases with fixed seeded
  output catch any change.
- **The `Run`-step regression** may break the conformance step itself. Mitigation: that is
  exactly what decision 1's early branch finds out.
- **A release built with 0.17 failing on a user's machine** (an older macOS, an unusual Linux).
  Mitigation: the dry release build, the install scripts' checks, and the stated minimums.

## Settled while building (2026-10-28, on 0.17.0)

The port was smaller than the counts in section 3 suggested, because 0.17.0 still accepts much of
what it deprecates. Following "the smallest fix 0.17 accepts":

- **Unchanged:** the 275 `allocPrint` calls, and the `-Doptimize=ReleaseSafe` spelling, which 0.17
  still accepts beside `safe`; CI, the release workflow, and the scripts keep it. Renaming either is
  later cleanup, not this upgrade.
- **Done by `zig fmt`:** 0.17's formatter rewrites the deprecated `@intFromEnum` as `@backingInt`
  itself, in 8 files, and changes nothing else.
- **`build.zig`:** `b.args` became `addPassthruArgs()` (four places); `.Debug` became `.debug`.
  0.17.0 no longer accepts a directory as an option *path* ("checking cache failed: file_read
  IsDir", likely the known build regression), so the conformance, examples, docs, and benchmarks
  directories are plain strings relative to the repository root. The conformance run step now
  starts there (`setCwd`) and always runs (`has_side_effects`), since Zig cannot see the cases it
  reads at run time as inputs.
- **Reflection:** `std.meta.fields` became `std.meta.fieldNames`, `@typeInfo`'s `fields` became
  `field_names`, and `std.meta.Int` and `std.meta.Tuple` became the `@Int` and `@Tuple` builtins.
  `std.heap.MemoryPoolAligned` became `std.heap.memory_pool.Aligned`.
- **Language:** `errdefer |err|` lost its capture, so the type-setup failure path became a `catch`
  around a new `runTypeSetup`; the array repetition operator `**` is gone, so five test strings use
  a small compile-time `repeated` helper; `std.fs.path.resolve` no longer adds the working
  directory, so the language-server conformance path is made absolute explicitly.
- **`@bitCast`:** all 11 convert between integers, or an integer and a float, of the same size
  (the seeded `Random` state, hashes, the prelude's float literals), where logical and memory bits
  agree. The conformance cases with seeded output pass unchanged.
- **Results on the development machine:** Debug and ReleaseSafe suites pass, `zig fmt --check` is
  clean, and ReleaseSafe builds for all three release targets produce Linux ELF, macOS Mach-O, and
  Windows PE binaries. The benchmarks, 0.16 against 0.17 alternating, show no program slower beyond
  noise (the largest, 1.04) and several faster: `json` 0.61, `regex` 0.70, `pipeline` 0.72,
  `sorting` 0.81 of the 0.16 time.
- **CI and the stall (item 9):** two memory tests failed on Linux and Windows. Probed in Docker,
  neither was a leak: the first measured run peaks 435 KB below every later one, and a program's
  peak sits at one of two levels about 250 KB apart, by program rather than by work. The tests now
  compare warmed-up long runs (a loop at 20,000 against 80,000 iterations, within 32 KB; calls at
  2,047 against 131,071, within 512 KB). Then 20 dispatched CI runs passed every job, 140 of 140,
  including the Windows Debug and ReleaseSafe suites in parallel with no `-j1`: 20 of 20 each,
  where the parallel Debug suite on 0.16 stalled about one run in two. The stall is gone.
- **Release:** a `release.yml` dry run built all three assets; the macOS arm64 and Linux x86-64
  ones match their checksums and run Emerald programs (Linux under emulation). The install scripts
  fetch only published releases, so they are checked at the first real one; the Windows asset was
  not run here.
