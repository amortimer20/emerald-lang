# Review area 5: cross-platform determinism

Branch `claude/review-platforms`, reviewing main at `d580f40`, Zig 0.17.0. Report only: nothing
under `src/`, `build.zig` or the tests was changed.

## Summary

| | Count |
| --- | --- |
| Findings: platform differences that the docs or spec don't allow | 3 (two are predicted for Windows and need a Windows run to confirm) |
| Documented differences (not findings) | 4 |
| Out-of-area defect found on the way | 1 (a crash, the same on every platform) |
| Probe programs | 10, plus 13 benchmarks |
| Windows probes still to run | 6 (commands below) |

The headline is good news. Every probe gives **byte-identical output** on macOS arm64 (native),
Linux aarch64 (native, in the `emerald-review` container) and Linux x86-64 (cross-built,
emulated). That covers float display at the extremes, `format`/`round_to`, about 1,700 lines of
`Math` results, seeded `Random`, `Dict`/`Set`/`frequencies` order, Unicode case mapping,
normalization and `Console.table` widths, named zones at DST edges back to 1883 and on to 2500,
CRLF/BOM file reads, and `Program.arguments`/`environment`. Every benchmark matches its
`.expected` on all three. All the differences found come from the host system: its path rules,
its zoneinfo files, and its directory order.

Byte-for-byte, the outputs differ only in:

- `files.out`, macOS vs Linux: `Directory.list` order, which is documented as unspecified;
- `zones-TZunset.out`: each machine's own zone, as expected.

The hashes for each platform are in `repro/platforms/reference/*.sha256`. The full Linux
aarch64 outputs are in `repro/platforms/reference/outputs/`.

## Method

- `repro/platforms/scripts/run-probes.sh EMERALD REPO OUT` runs every probe in
  `repro/platforms/probes/` and every benchmark, saving stdout, stderr and the exit code. It runs
  `zones.em` with 11 `TZ` values: IANA names, `EST5EDT`, a full POSIX rule, `:name`, empty, an
  unknown name, `<+0530>-5:30`, and unset.
- `repro/platforms/scripts/sweep-zones.sh` sets `TZ` to every zone file on the system and
  compares `TimeZone.local` with `TimeZone(name)` at the start of every month from 1970 to 2040.
  They agreed for all 597 zones on macOS (system tzdata 2026e) and all 446 on Ubuntu 24.04
  (2026e), against the built-in 2026d.
- `repro/platforms/scripts/path-semantics.zig` prints what the `std.fs.path` functions behind
  `Path` return under POSIX and Windows rules. That is how the Windows `Path` results below were
  predicted.
- Builds:
  - macOS: native ReleaseSafe.
  - Linux aarch64: native ReleaseSafe and Debug in the container.
  - Linux x86-64: cross-built, run under `docker run --platform linux/amd64 ubuntu:24.04`. It
    ran once without tzdata, and once with the container's zoneinfo mounted and
    `/etc/localtime` linked to `Etc/UTC`.
  - Windows x86-64: cross-built only.

## Findings

### P1. `Path.name`, `stem`, `extension`, `parent` and `absolute?` follow the host's rules, but `Path.join` doesn't (Windows, predicted)

Reproduction: `repro/platforms/path-backslash.em`.

```emerald
print(Path.name("notes\\week1.txt"), "|", Path.parent("notes\\week1.txt"), "|", Path.extension("a\\b.c\\d"))
print(Path.absolute?("C:\\Users\\ada"), Path.absolute?("C:/Users/ada"), Path.absolute?("\\\\server\\share"))
print(Path.parent(Path.join(["C:\\Users\\ada", "notes.txt"])))
```

macOS, Linux aarch64 and Linux x86-64, observed:

```text
notes\week1.txt |  | c\d
false false false
C:\Users\ada
```

Windows, predicted from `std.fs.path.*Windows` (`scripts/path-semantics.zig`):

```text
week1.txt | notes | 
true true true
C:\Users\ada
```

`Interpreter.zig` sends `name`, `stem`, `extension`, `parent` and `absolute?` straight to
`std.fs.path.basename`, `stem`, `extension`, `dirname` and `isAbsolute`, which take on the
target's rules. `Path.join` deliberately doesn't: `joinPathParts` says "a joined path reads the
same on every platform". So a program gives different answers depending on where it runs.

The spec only says these operations are "lexical path manipulation" (rewrite-context 15.3;
`docs/library/file.md` says "lexical only"). Neither document says the lexical rules depend on
the host, and `Path.join`'s own comment holds the opposite principle. Either the five operations
should follow one rule everywhere, or the docs should say they follow the host's.

### P2. `Path.absolute` gives back the host's separators, and `Path.join` then appends `/` (Windows, predicted)

Reproduction: `repro/platforms/path-absolute-mixed.em`. It prints whether
`Path.join([Path.absolute(f), "child"])` contains `\` and `/`.

- macOS and Linux, observed: `false true`.
- Windows, predicted: `true true`, a path like `C:\Users\ada\probe-absolute.txt/child`.
  `realPathFileAlloc` returns `\` on Windows, and `joinPathParts` always inserts `/`.

The Windows APIs accept the mixed path, but it is what a beginner prints. It follows from P1
and should be settled by the same decision.

### Z1. `TZ` set to a zone name finds the zone only in the system's zoneinfo, never in the built-in database (macOS vs a minimal Linux)

Reproduction: `repro/platforms/tz-legacy-name.em`, run with `TZ=GB` and with `TZ=US/Eastern`.

```text
macOS        TZ=GB:          GB 1h 1h -4h
macOS        TZ=US/Eastern:  US/Eastern -4h 1h -4h
Ubuntu 24.04 TZ=GB:          UTC 0s 1h -4h
Ubuntu 24.04 TZ=US/Eastern:  UTC 0s 1h -4h
```

The same thing happens for every name, including `TZ=America/New_York`, on a Linux machine
without the `tzdata` package. The official `ubuntu:24.04` image, many CI and Docker images, and
WSL minimal installs are all like that. Every line of `zones-TZ=America_New_York.out` then
changes: `local: UTC`, offsets `0s`, and `local == TimeZone("America/New_York")` is `false`.
Ubuntu 24.04 also no longer ships the old link names (`GB`, `US/*`), which moved to
`tzdata-legacy`. In every case `TimeZone("GB")` and `TimeZone("US/Eastern")` in the same program
work, from the built-in copy.

What the docs promise:

- `time-zone.md` says `TimeZone.local` reads `TZ` "the way the C library does", and that
  anything unreadable gives UTC. That much is documented, and glibc does the same.
- But rewrite-context's decision table (row "Where named zones' rules come from (15.8)") gives
  the reason for building the database in: "Linux and macOS carry whatever release the machine
  last installed, so the same program would give different answers." `time-zone.md` promises
  "a zone gives the same answer on every operating system."

So the local zone is the one place where a named zone still depends on the host's files.
Suggested decision: when `TZ` names a zone that the system can't read, fall back to the
built-in zone of that name before falling back to UTC.

The sweep found no zones where the rules themselves differ today, because the system files and
the built-in copy agree from 1970 to 2040. So this is only a difference when a file is missing,
for now.

### Z2 (minor). The local zone's name is the raw text after `zoneinfo/`, so equal zones can compare unequal

Reproduction: `repro/platforms/tz-local-name.em`.

```text
macOS  TZ=/usr/share/zoneinfo//Europe/London                     -> /Europe/London false
Linux  TZ=/usr/share/zoneinfo//Europe/London                     -> /Europe/London false
macOS  TZ=/var/db/timezone/zoneinfo/../zoneinfo/Europe/London    -> Europe/London true
Linux  TZ=/usr/share/zoneinfo/Europe/../Europe/London            -> Europe/../Europe/London false
Linux  TZ unset, /etc/localtime -> /usr/share/zoneinfo//UTC      -> local: /UTC
```

The last line is the `emerald-review` container as it is set up. A doubled slash is common in
Dockerfiles that use `ln -snf /usr/share/zoneinfo/$TZ /etc/localtime`.

`time-zone.md` says "Two zones are equal when their names are." So on such a machine,
`TimeZone.local == TimeZone("UTC")` is `false`, and the zone prints as `/UTC`.
`TimeZone.zoneNameOf` takes whatever follows the last `zoneinfo/` without normalizing it. The
right result depends on how each machine was set up, not on the OS as such, but it is the same
kind of non-portability.

## Documented differences (not findings)

1. **`Directory.list` order.** On ext4/overlayfs, Linux gives
   `10.txt, b.txt, éx.txt, 9.txt, é.txt, …`. APFS gives `é.txt, 10.txt, Z, 9.txt, _, …`.
   The spec says "unsorted" and `file.md` says "their order is unspecified". Sorted, the lists
   are identical. APFS keeps NFC and NFD names distinct, as ext4 does.
2. **`TimeZone.local` with `TZ` unset** follows `/etc/localtime`, and Windows ignores `TZ`
   (`build.zig` and `time-zone.md` both say so).
3. **`Program.environment` names ignore case on Windows** (`program.md`). On macOS and Linux,
   `environment("em_probe")` is `nothing` when `EM_PROBE` is set.
4. **`Float.hash`/`String.hash` values** may change between runs (`float.md`, 8.4). The probes
   don't print them. `Dict` and `Set` iteration was checked separately and is insertion order on
   all three platforms: a 300-key dictionary with deletions and re-insertions, a 200-element
   `Set[Float]` including `-0.0`, and a 5,000-key checksum (`collections.out`).

## Things checked and found identical on macOS, Linux aarch64 and Linux x86-64

- **Floats** (`floats.em`): subnormals, `1e308`, `±Infinity`, `-0.0`, `NaN`, the `1e-6` and
  `1e16` notation boundaries, `format(decimal_places:)` up to 100 places, grouping, and
  `round_to` from −308 to 323 places.
- **`Math`** (`math.em`): `sin`, `cos`, `tan`, `arc_*`, `arc_tan2`, `natural_log`, `log10`,
  `log(x, b)`, `power`, `**`, `square_root` and the angle conversions, at 423 inputs including
  `1e22`, `1e300`, `710`, signed zeros and infinities. All 1,695 lines are identical, so the
  macOS build doesn't switch to Apple's libm: all three use Zig's compiler_rt routines. The
  Linux aarch64 Debug build matches too (see the note at the end).
- **Seeded `Random`** (`random.em`): 6 seeds including `Int` min and max, with `next`,
  `next_fraction`, `next` over the full `Int` range, `shuffle!` and `choose`.
- **Unicode** (`unicode.em`): `upper`, `lower`, `capitalize` and `reverse` of `ß`, `İ`, `ǅ`,
  final sigma, ligatures, ZWJ families, flags, Indic conjuncts, Hangul jamo and Deseret;
  normalization equality; sort order; `Console.table` with wide, emoji, combining, ZWSP, soft
  hyphen and tab cells; `pad_*` with a wide fill. These all come from tables built into Emerald,
  so no host library is involved.
- **Files** (`files.em`): `read_lines`, `read_line` and `String.lines` on CRLF, CR CR LF and a
  trailing lone CR; `write`/`write_lines` producing LF only; a BOM file. Note that the BOM is
  kept as U+FEFF at the start of `read` and of the first `read_lines` item on every platform.
  That is consistent, and only `Csv` documents stripping it, but it matters most on Windows,
  where editors write BOMs.
- **Program** (`program.em`): arguments with spaces, empty, `\"`, Unicode and emoji, `--` and
  `a=b`; an environment value with ZWJ emoji; the empty and `=` names; `exit(8)`.
- **Zones** (`zones.em`): ten zones including Lord Howe's 30-minute DST, Casablanca, Apia's
  dateline jump, the 1883 local mean time and 2038/2100/2500, under every `TZ` form. All are
  identical wherever the same zoneinfo is present.
- **Benchmarks**: all 13 `.expected` files reproduce on Linux aarch64, Linux x86-64 and macOS.

## Windows: still to run

I couldn't run Windows, so P1, P2 and the rows below are unconfirmed there. From Git Bash in a
checkout of this branch on a Windows machine:

```bash
zig build -Doptimize=ReleaseSafe
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
sh docs/review/repro/platforms/scripts/run-probes.sh "$PWD/zig-out/bin/emerald.exe" "$PWD" "$PWD/out-win"
(cd out-win && sha256sum *.out *.err 2>/dev/null) > win.sha256
diff <(grep -v -e bench- -e zones-TZ -e '\.err' docs/review/repro/platforms/reference/linux-aarch64.sha256 | sort -k2) \
     <(grep -v -e bench- -e zones-TZ -e '\.err' win.sha256 | sort -k2)
cat out-win/benchmarks-summary.txt
diff out-win/zones-TZunset.out out-win/zones-TZ=America_New_York.out | head   # expect only the machine zone to differ
./zig-out/bin/emerald.exe run docs/review/repro/platforms/path-backslash.em      # P1: expect "week1.txt | notes |", "true true true"
./zig-out/bin/emerald.exe run docs/review/repro/platforms/path-absolute-mixed.em # P2: expect "true true"
```

In the `diff`, expect `files.out` (directory order and the P1 lines) and `program.out` (the
`em_probe` line) to differ. Anything else in `floats`, `math`, `random`, `unicode` or
`collections` is a new finding.

From PowerShell, which quotes arguments natively rather than through MSYS:

```powershell
$env:EM_PROBE = 'Ünï ✓ 東京 👩‍👩‍👧'; $env:EM_EMPTY = ''
./zig-out/bin/emerald.exe run docs/review/repro/platforms/probes/program.em -- 'two words' 'Ünïcödé' '""' 'e\"q' '東京 👍🏽' '-x' '--' 'a=b'; "exit $LASTEXITCODE"
./zig-out/bin/emerald.exe run docs/review/repro/platforms/probes/unicode.em > unicode-win.out
```

Compare the program output with `reference/outputs/program.out`. Expect `em_probe` to find the
variable. PowerShell 5 drops an empty `''` argument, which is why it is written `'""'` above.
Then compare `unicode-win.out` with `reference/outputs/unicode.out` byte for byte. That checks
Console output encoding when redirected.

Also worth a look on Windows: `TimeZone.local` for a zone with no CLDR mapping, and for a
machine with "Adjust for daylight saving time automatically" turned off
(`DynamicDaylightTimeDisabled`, which `windowsZone` doesn't read).

## Out of area: `group_by` aborts on five or more items in one group

Reproduction: `repro/platforms/crash/group-by-count.em`, which is
`print("a b c d e".split(" ").group_by { w => w.count })`. On macOS, Linux aarch64 and Linux
x86-64 alike it panics with "reached unreachable code", an assertion reached through
`Interpreter.zig:9092` (`callGroupBy`), and exits with 134. Four items work; five abort. This
is not a platform difference. It is passed on for the collections area.

## Debug vs ReleaseSafe

On Linux aarch64, a Debug build gives byte-identical output to ReleaseSafe for all 19 probe
outputs, so optimization level does not change float results either. Benchmarks in Debug were
not timed or rechecked: CI already runs the conformance suite in both modes.
