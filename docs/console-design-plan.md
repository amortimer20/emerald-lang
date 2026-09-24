# Console styling: design and implementation plan

Status: design handoff, 2026-09-24. This records the user's direction and a proposed
implementation sequence for the first `Console` slice. It does not authorize
implementation, commits, or pushes by itself. Read AGENTS.md and the current handoff before
acting; repository state takes precedence over remembered conversations. At the start of
each slice, reread `git status`, the recent `git log`, relevant diffs, and docs/handoff.md.
Other agent work may have landed since this plan was written; preserve and reconcile it.

## Objective and accepted direction

`Console` is the first of the official platform libraries (rewrite-context's roadmap: Console,
Tui, Graphics, Gui, Audio, Game — separate libraries, shipped with Emerald). Its first slice
is terminal styling of individual strings. Prompts, multi-select, tables, RGB colors,
reusable style objects, and anything full-screen are later slices or later libraries.

Accepted by the user after a Claude/Codex design pass:

- **Styled values are ordinary `String`s** containing ANSI SGR escape sequences. No
  `StyledText` type, no change to interpolation, no new display machinery. `print`,
  interpolation, assignment, and `+` work unchanged. The known costs are accepted: escape
  bytes count toward `count`, indexing, slicing, and searching, and a styled string written
  to a file carries its escape bytes. Guidance: style at the output boundary
  (`print("Result: #{Console.green(status)}")`), not in stored data.
- **Local styling only.** No C#-style persistent foreground/background state.
- **One color policy per execution, owned by the runtime**, not a process global and not a
  mutable Emerald-level switch. Every helper reads the same decision, so a message cannot be
  half-styled by a policy change partway through building it. Tests and embedded runs set
  it explicitly.
- **Small API:** eight foreground helpers plus four text styles; everything else goes
  through `Console.style`.
- **Correct nesting** through style-specific close codes and re-opening enclosing styles.
- **`Console.plain` removes recognized SGR sequences only.**

## Verified constraints (checked against source, 2026-09-24)

- **Nested types exist** (implemented 2026-09-24 in `0f939f1` through `9f88729`, see
  `docs/nested-types-design-plan.md` and rewrite-context 14.3), so the color type is a
  nested enum, `Console.Color`. Verified in the prelude specifically: a temporary nested
  enum in `class Random` was reachable as `Random.Mode.fair` in values, annotations, and an
  exhaustive `case`, and displayed as `Random.Mode.fair`. Its key is `emerald.Console::Color`.
- Built-in namespaces are prelude classes with type-level functions (`class File { func
  File.read(...) }`), with native dispatch by key prefix (`Interpreter.isFilesystemKey`).
  `Console` follows the same pattern.
- `Interpreter.run` receives `out: *std.Io.Writer` and never sees the underlying file, so it
  cannot detect a terminal itself. `emerald.Streams` (`out`, `in`, `arguments`) is the
  runtime's output configuration and the natural home for the policy. Every existing
  caller — REPL, Zig tests, conformance, fuzz — constructs `Streams` with defaults.
- `main.zig` has no TTY detection, color handling, or environment reading today.
- Pinned Zig 0.16.0 provides `std.Io.File.isTty`, `enableAnsiEscapeCodes`, and
  `supportsAnsiEscapeCodes`. Windows console setup needs no hand-written Win32 calls.
- `"\u{1B}"` is a valid Emerald escape, so tests can assert exact sequences in source:
  `assert Console.green("x") == "\u{1B}[32mx\u{1B}[39m"`. Ordinary defaulted parameters
  work, which `Console.style` needs.
- No existing example, conformance case, or source file declares `Console`, so adding it
  to the prelude breaks nothing in-tree.

## Decisions

Decision 1 was settled by implementing nested types. The user deferred decisions 2 through 5
to the recommendations below (2026-09-24), noting that the REPL should display color, so each
is settled as recommended.

1. **Color type spelling.** Resolved: `Console.Color`, a nested enum. The user chose to
   implement 14.3's nested types first rather than add a top-level `ConsoleColor`, and they
   now exist. A file that writes the color often can alias it:
   `using Color = Console.Color`.
2. **Explicit control surface.** Recommended: a CLI flag `--color=auto|always|never` on
   `run` and `test`, plus the `NO_COLOR` and `FORCE_COLOR` environment variables. The flag
   is the discoverable, per-invocation control a beginner can see in `emerald help`; the
   environment variables are what other terminal tools already honor. No Emerald-level
   switch in this slice. Alternative: environment variables only, adding no CLI surface.
3. **Precedence.** Recommended, highest first:
   1. `--color=always` or `--color=never`.
   2. `NO_COLOR` present and non-empty: off (per no-color.org, which says CLI arguments
      override it).
   3. `FORCE_COLOR` present, non-empty, and not `0`: on.
   4. `TERM=dumb`: off.
   5. Otherwise, on only when stdout is a TTY that supports ANSI escapes.

   If both `NO_COLOR` and `FORCE_COLOR` are set, `NO_COLOR` wins as the safer reading.
4. **A full reset inside styled input.** Recommended: when wrapping text that contains
   `ESC[0m`, re-open this layer's style after it, just as after the layer's own close code.
   Each nested layer does the same, so every enclosing style survives a reset from inside.
   Alternative: leave `ESC[0m` untouched, so an inner full reset ends all outer styling.
5. **REPL.** Recommended: the REPL resolves the policy the same way `run` does, so
   `Console.green("hi")` in an interactive terminal shows green. Alternative: always off.

## Specified behavior

### API (prelude, all type-level, all return `String`)

```emerald
Console.black(text: String): String
Console.red(text: String): String
Console.green(text: String): String
Console.yellow(text: String): String
Console.blue(text: String): String
Console.magenta(text: String): String
Console.cyan(text: String): String
Console.white(text: String): String

Console.bold(text: String): String
Console.dim(text: String): String
Console.italic(text: String): String
Console.underline(text: String): String

Console.style(
    text: String,
    foreground: Console.Color? = nothing,
    background: Console.Color? = nothing,
    bold: Bool = false,
    dim: Bool = false,
    italic: Bool = false,
    underline: Bool = false
): String

Console.plain(text: String): String
```

`Console.Color` has sixteen values: `black`, `red`, `green`, `yellow`, `blue`, `magenta`,
`cyan`, `white`, and `bright_black` through `bright_white`. `nothing` means the terminal's
default. Bright colors and backgrounds are reached only through `Console.style`.

When the policy is off, every helper and `Console.style` returns `text` unchanged. So does
`Console.style` with no options. `Console.plain` behaves the same under either policy.

### SGR codes

| Style | Open | Close |
| --- | --- | --- |
| Foreground, basic | `30`–`37` | `39` |
| Foreground, bright | `90`–`97` | `39` |
| Background, basic | `40`–`47` | `49` |
| Background, bright | `100`–`107` | `49` |
| Bold | `1` | `22` |
| Dim | `2` | `22` |
| Italic | `3` | `23` |
| Underline | `4` | `24` |

Each sequence is `ESC [ <code> m`. `Console.style` applies each requested attribute as its
own layer, in a fixed documented order (foreground, background, bold, dim, italic,
underline), each wrapped with the nesting rule below. Pick one order and pin it with a test.

### Nesting

Wrapping `text` in one attribute with open `O` and close `C` produces:

```text
O + text' + C
```

where `text'` is `text` with every occurrence of `C` replaced by `C + O` (and, if decision 4
is approved, every `ESC[0m` replaced by `ESC[0m + O`). So after an inner span closes, the
outer style comes back:

- `Console.green("a #{Console.red("b")} c")`: the inner close `39` becomes `39` + `32`, so
  " c" is green again rather than the default color.
- `Console.bold("a #{Console.dim("b")} c")`: bold and dim share close code `22`, so the
  inner `22` becomes `22` + `1`, and " c" is bold again. This shared code is the case most
  likely to be wrong and needs its own tests in both directions.

Output outside the styled value is never affected, because every value ends with its own
close codes.

### `Console.plain`

Removes every complete SGR sequence: `ESC`, `[`, zero or more characters from `0`–`9` and
`;`, then `m`. Everything else is kept as is: other CSI sequences such as cursor movement,
bare `ESC` characters, and incomplete or malformed sequences. `plain` removes Console's
own styling. It is not a terminal-security sanitizer, and its docs should say so.

### Policy plumbing

- Add `color: bool = false` to `emerald.Streams`. The default keeps every existing caller —
  REPL tests, Zig tests, conformance, fuzz — deterministic and unstyled no matter what host
  runs them.
- `main.zig` resolves decision 3's precedence into that bool before calling `runProject` or
  `testProject` (and the REPL, per decision 5). Write the resolution as a pure function of
  its inputs (flag value, the two environment variables, `TERM`, TTY/ANSI support) so every
  precedence case gets a Zig unit test without a real terminal.
- On Windows, call `enableAnsiEscapeCodes` only when auto-detection has decided on color.
  When `--color=always` or `FORCE_COLOR` forces color onto redirected output, emit the
  sequences without touching the console: there is no console to configure, and the reader
  of that output (a file, a pipe, CI logs) interprets them.
- Thread the bool into `Interpreter` alongside `out`. The `Console.*` native dispatch reads
  it. Nothing else in the interpreter changes behavior.

## Implementation map to verify

- `src/prelude.em`: `class Console`, with the nested `enum Color` and type-level signatures,
  using the same "ordinary signature, native body" convention as `File`.
- `src/Interpreter.zig`: an `isConsoleKey`/`callConsole` pair modeled on
  `isFilesystemKey`/`callFilesystem`. Implement the nesting rule, `plain`'s scanner, and
  `Console.Color` → code mapping. Build results with `heap.createText`, the same way string
  concatenation in `applyBinary` does.
- `src/emerald.zig`: the `Streams.color` field, passed through `onLargeStack` into
  `Interpreter.run`.
- `src/main.zig` and `src/arguments.zig`: `--color` parsing and validation, the pure
  precedence function, environment reads, `isTty`/`supportsAnsiEscapeCodes`, and Windows
  enabling. Add the flag to `run`/`test` help text and to the relevant `emerald explain`
  or usage diagnostics.
- `src/Repl.zig`: accept and forward the resolved policy (decision 5).
- `src/conformance.zig` and `conformance/README.md`: a new `color/` case directory with
  `run` semantics and `Streams.color = true`. Every other directory keeps color off.
- Checker, Resolver, Formatter, and LSP: no changes expected. `Console` is an ordinary
  prelude class, so hover, completion, and go to definition come with it. Verify rather
  than assume.

## Runnable implementation slices

1. **Helpers under a forced policy.** `Console.Color`, the twelve helpers, `Console.style`,
   the nesting rule, `Streams.color`, and the `conformance/color/` directory. Cases assert
   exact sequences in source with `"\u{1B}"`, including nested foreground,
   foreground-in-background, bold/dim both ways, a full reset in input (per decision 4),
   and `style` layer order. `conformance/run/` cases confirm every helper is the identity
   with color off. No CLI changes yet: the policy is only reachable by tests.
2. **`Console.plain`.** The SGR scanner, cases for stripping every styled output from slice
   1, and cases that keep cursor sequences, bare `ESC`, and incomplete sequences intact.
3. **Real terminals.** `--color`, environment precedence, TTY detection, Windows
   enabling, and REPL forwarding. Zig unit tests cover the pure precedence function. Then
   check by hand: a real terminal shows color; `> file` and `| cat` show none; each
   variable and flag overrides as specified; Windows CI stays green.
4. **Documentation and integration.** `docs/library/console.md`, an `inventory.md` entry, a
   rewrite-context §15 subsection with decision-table rows for the representation choice,
   the policy, precedence, nesting, and `plain`'s scope, and a small `examples/` program. It
   must behave with piped stdout and no arguments, since `tools/check-doc-examples.sh` runs
   every example that way. Update the handoff.

Keep each slice runnable; commit only when authorized. Do not push without authorization.

## Tests and completion criteria

Read every expected output by hand; do not bless generated output. Golden files containing
raw `ESC` bytes are hard to read, so prefer in-program `assert`s against `"\u{1B}"` literals,
with printed output only confirming the asserts ran. Verify existing `print`,
interpolation, `String`, and `Bytes` behavior is unchanged.

Follow the pinned toolchain and run `tools/check-toolchain.sh`. Required final validation:
Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh`,
and `git diff --check`. Report actual results and blockers.

Done means the twelve helpers, `Console.style`, and `Console.plain` behave as specified. It
also means styling appears in a real terminal and disappears when output is redirected or
turned off, and nesting restores enclosing styles, including bold and dim. The policy
resolves in the documented order on all three CI platforms, and docs record the design and
its accepted costs.
