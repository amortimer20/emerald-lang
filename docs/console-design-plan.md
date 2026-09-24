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
  exhaustive `case`, and displayed as `Random.Mode.fair`. Its key is `Emerald.Console::Color`.
- **The built-ins live in the `Emerald` namespace** (rewrite-context 14.2, 15.1, completed
  2026-09-24). `Console` is one more built-in: `Emerald.Console.green(...)` works with no
  extra code, and a program that declares its own `Console` still runs, with a warning. Every
  prelude key starts with `Resolver.prelude_namespace` (`"Emerald"`); never hardcode that
  string in the interpreter, since nine hardcoded copies had to be replaced when it changed.
- Built-in namespaces are prelude classes with type-level functions (`class File { func
  File.read(...) }`), with native dispatch by key prefix (`Interpreter.isFilesystemKey`).
- **Native dispatch evaluates arguments by position only** (`callFilesystem` calls
  `evaluateArguments(call.arguments)`), and no prelude function has ever had a default
  parameter. A native `Console.style` would therefore mishandle `Console.style("x",
  bold: true)`. This is why the implementation approach below writes the helpers in Emerald
  and keeps native code to two single-argument primitives.
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

All five are settled (2026-09-24); none is open for the executor to revisit. Decision 1 was
settled by implementing nested types; the user deferred 2 through 5 to the recommendations,
noting that the REPL should display color.

1. **Color type spelling.** Resolved: `Console.Color`, a nested enum. The user chose to
   implement 14.3's nested types first rather than add a top-level `ConsoleColor`, and they
   now exist. A file that writes the color often can alias it:
   `using Color = Console.Color`.
2. **Explicit control surface.** A CLI flag `--color=auto|always|never` on `run` and `test`,
   plus the `NO_COLOR` and `FORCE_COLOR` environment variables. The flag is the
   discoverable, per-invocation control a beginner can see in `emerald help`; the
   environment variables are what other terminal tools already honor. No Emerald-level
   switch in this slice.
3. **Precedence**, highest first:
   1. `--color=always` or `--color=never`.
   2. `NO_COLOR` present and non-empty: off (per no-color.org, which says CLI arguments
      override it).
   3. `FORCE_COLOR` present, non-empty, and not `0`: on.
   4. `TERM=dumb`: off.
   5. Otherwise, on only when stdout is a TTY that supports ANSI escapes.

   If both `NO_COLOR` and `FORCE_COLOR` are set, `NO_COLOR` wins as the safer reading.
4. **A full reset inside styled input.** When wrapping text that contains `ESC[0m`, re-open
   this layer's style after it, just as after the layer's own close code. Each nested layer
   does the same, so every enclosing style survives a reset from inside.
5. **REPL.** The REPL resolves the policy the same way `run` does, so `Console.green("hi")`
   in an interactive terminal shows green.

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
own layer, innermost first, in this order: foreground, background, bold, dim, italic,
underline. So `Console.style("w", foreground: Console.Color.bright_yellow, background:
Console.Color.blue, bold: true)` is exactly
`ESC[1m ESC[44m ESC[93m w ESC[39m ESC[49m ESC[22m` (spaces added here for reading only).

### Nesting

Wrapping `text` in one attribute with open `O` and close `C` produces:

```text
O + text' + C
```

where `text'` is `text` with every occurrence of `C` replaced by `C + O`, and every `ESC[0m`
replaced by `ESC[0m + O` (decision 4). So after an inner span closes, the
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

## Implementation approach (prototyped 2026-09-24)

Write `Console` in Emerald, in `src/prelude.em`, on top of two native primitives. Ordinary
Emerald functions go through the interpreter's normal call path, which already handles named
and defaulted arguments, optional narrowing, and nested enums. This was prototyped as a
user-level class, and every assertion below passed:

```emerald
class Console {
    enum Color {
        black, red, green, yellow, blue, magenta, cyan, white
        bright_black, bright_red, bright_green, bright_yellow
        bright_blue, bright_magenta, bright_cyan, bright_white
    }

    # Native: the execution's color policy (`Streams.color`).
    func Console._color(): Bool {
        return false
    }

    func Console._layer(text: String, open: Int, close: Int): String {
        const o = "\u{1B}[#{open}m"
        const c = "\u{1B}[#{close}m"
        const reset = "\u{1B}[0m"
        return o + text.replace(c, c + o).replace(reset, reset + o) + c
    }

    func Console._code(color: Console.Color): Int {
        return case color {
            when Console.Color.black then 30
            # ... red 31 through white 37, bright_black 90 through bright_white 97
        }
    }

    func Console.style(text: String, foreground: Console.Color? = nothing, background: Console.Color? = nothing, bold: Bool = false, dim: Bool = false, italic: Bool = false, underline: Bool = false): String {
        if not Console._color() {
            return text
        }
        var result = text
        if foreground != nothing {
            result = Console._layer(result, Console._code(foreground), 39)
        }
        if background != nothing {
            result = Console._layer(result, Console._code(background) + 10, 49)
        }
        if bold {
            result = Console._layer(result, 1, 22)
        }
        # ... dim (2, 22), italic (3, 23), underline (4, 24), in that order
        return result
    }

    func Console.green(text: String): String {
        return Console.style(text, foreground: Console.Color.green)
    }
    # ... the other seven colors and bold/dim/italic/underline the same way

    # Native: the SGR scanner.
    func Console.plain(text: String): String {
        return text
    }
}
```

Prototype assertions (with `E = "\u{1B}"`), which slice 1's conformance cases should carry:

```emerald
assert Console.green("x") == "#{E}[32mx#{E}[39m"
assert Console.green("a #{Console.red("b")} c") == "#{E}[32ma #{E}[31mb#{E}[39m#{E}[32m c#{E}[39m"
assert Console.bold("a #{Console.dim("b")} c") == "#{E}[1ma #{E}[2mb#{E}[22m#{E}[1m c#{E}[22m"
assert Console.style("plain") == "plain"
```

Notes for the executor:

- Emerald negation is `not`, not `!`. Division `/` yields `Float`; use `//` for `Int`.
- The Emerald bodies of `_color` and `plain` above are placeholders. The interpreter must
  intercept exactly the two keys `Emerald.Console::_color` and `Emerald.Console::plain`,
  built from `Resolver.prelude_namespace`. Do **not** intercept every `Console::` key by
  prefix, the way `isFilesystemKey` does for `File`: every other `Console` function has a
  real Emerald body that must run through `callFunction`.
- The prototype resolved `Con.Color` inside a user file's signatures. `Console.Color` inside
  the prelude's own signatures has not been tried; confirm it first in slice 1, before
  writing the rest.
- The private helpers (`_color`, `_layer`, `_code`) follow 10.5's braces rule, so programs
  cannot call them. Check whether LSP completion after `Console.` lists them; if it does,
  filter private names there.

## Implementation map to verify

- `src/prelude.em`: `class Console` as above.
- `src/Interpreter.zig`: intercept the two native keys; `_color` returns the policy and
  `plain` runs the SGR scanner, building its result with `heap.createText` the way string
  concatenation in `applyBinary` does.
- `src/emerald.zig`: the `Streams.color` field, passed through `onLargeStack` into
  `Interpreter.run`.
- `src/main.zig` and `src/arguments.zig`: `--color` parsing and validation, the pure
  precedence function, environment reads, `isTty`/`supportsAnsiEscapeCodes`, and Windows
  enabling. Add the flag to `run`/`test` help text, and report an unknown value such as
  `--color=blue` as a usage error naming the three valid values.
- `src/Repl.zig`: accept and forward the resolved policy (decision 5).
- `src/conformance.zig` and `conformance/README.md`: a new `color/` case directory. Add
  `.color` to the `Kind` enum and `Kind.fromPath`, run it exactly like `.run` but with
  `Streams.color = true`, and add its row to the README's table. Every other directory keeps
  color off.
- Checker, Resolver, Formatter, and LSP: no changes expected. `Console` is an ordinary
  prelude class, so hover, completion, and go to definition come with it. Verify rather
  than assume.

## Runnable implementation slices

1. **Helpers under a forced policy — completed in `0904ec7`.** `Console.Color`, the twelve helpers, `Console.style`,
   the nesting rule, `Streams.color`, and the `conformance/color/` directory. Cases assert
   exact sequences in source with `"\u{1B}"`, including nested foreground,
   foreground-in-background, bold/dim both ways, a full reset in input (per decision 4),
   and `style` layer order. `conformance/run/` cases confirm every helper is the identity
   with color off. No CLI changes yet: the policy is only reachable by tests. The prelude
   bodies qualify their internal calls as `Emerald.Console`, rather than bare `Console`, so a
   program's own `Console` cannot capture those calls. The resolver likewise keeps the
   prelude's `Emerald` path stable while recovering from an invalid declaration of the
   reserved name. Completion now omits private type members such as `_color`, `_layer`, and
   `_code`.
2. **`Console.plain` — completed in `9db62f7`.** The native scanner strips
   complete SGR sequences while retaining every other sequence. Focused assertions cover
   styled output from slice 1, a multi-code SGR sequence, cursor controls, bare `ESC`, and
   incomplete or malformed sequences. `plain` has the same result with color policy on or off.
3. **Real terminals — completed in `7811a0f`.** `--color`, environment
   precedence, TTY detection, Windows enabling, and REPL forwarding. The pure `ColorPolicy`
   function has unit tests for every precedence tier, while binary-level tests cover the CLI,
   program arguments, and forced output. Linux manual probes verified the pseudo-terminal and
   pipe behavior below; Windows VT setup has CI coverage only. Then
   check the real binary: under a pseudo-terminal color appears (on Linux,
   `script -qc 'emerald run x.em' /dev/null | cat -v` shows `^[[32m`), while `> file` and
   `| cat` show none, and each variable and flag overrides as specified. Windows is checked
   only by CI; say so rather than claim it was tested locally.
4. **Documentation and integration — implemented locally, awaiting commit.**
   `docs/library/console.md`, an `inventory.md` entry, rewrite-context §15.6 with decision-table
   rows in §22 for the representation choice, the policy, precedence, and nesting/`plain`'s
   scope, and `examples/console.em`. The example runs cleanly with piped stdout and no
   arguments (`tools/check-doc-examples.sh`'s own invocation), and was also run directly both
   plain and with `--color=always`. The handoff is updated.

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
