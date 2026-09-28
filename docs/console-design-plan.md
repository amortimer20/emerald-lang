# Console tables, panels, and prompts: design and implementation plan

Status: proposed, 2026-09-28, awaiting the user's decisions below. Rewrite-context 15.6 and 24
leave two pieces of `Console` for later slices of the same library: layout widgets (`Table`,
`Panel`) and line-oriented prompts (confirm, text input, single and multiple choice). This plan
designs both. A full-screen terminal library stays parked (24): nothing here needs raw-mode
input or a redraw loop.

The executor makes the remaining judgement calls within a slice and records each one under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally and look finished when it runs.

```emerald
struct Score {
    const name: String
    const points: Int
}

const scores = [Score("Ada", 120), Score("Grace", 95), Score("Hopper", 88)]
print(Console.table(scores))

print(Console.panel("You found the golden key!\nThe door creaks open.", title: "Level 2"))

const name = Console.ask("What's your name?")
const age = Console.ask_int("How old are you?", minimum: 0, maximum: 150)
const level = Console.choose("Pick a difficulty", ["Easy", "Normal", "Hard"])
const toppings = Console.choose_many("Any toppings?", ["Cheese", "Mushrooms", "Olives"])
if Console.confirm("Play again?") {
    print("Here we go, #{name}!")
}
```

It prints:

```text
┌────────┬────────┐
│ name   │ points │
├────────┼────────┤
│ Ada    │    120 │
│ Grace  │     95 │
│ Hopper │     88 │
└────────┴────────┘
┌─ Level 2 ─────────────────┐
│ You found the golden key! │
│ The door creaks open.     │
└───────────────────────────┘
```

And a session with the prompts looks like this, the student's typing after each prompt:

```text
What's your name? Ada
How old are you? twelve
Please enter a whole number.
How old are you? 12
Pick a difficulty
  1. Easy
  2. Normal
  3. Hard
Choose 1-3: 2
Any toppings?
  1. Cheese
  2. Mushrooms
  3. Olives
Choose any of 1-3, separated by commas, or press Enter for none: 1, 3
Play again? (y/n) y
Here we go, Ada!
```

## Principles

1. **Widgets make text; `print` shows it.** `Console.table` and `Console.panel` return a
   `String`, like the styling helpers (15.6). A program can print it, save it to a file, or put
   it inside a panel. Nothing in `Console` prints behind the program's back except the prompts,
   whose whole job is a conversation.
2. **Columns line up with any text.** Widths are measured in terminal columns, not characters:
   a Chinese character or an emoji takes two columns, and Console's own styling takes none, so
   a table of colored or non-English cells still lines up (decision 3).
3. **A prompt asks until it gets a usable answer.** The classic beginner loop, "read a line,
   try to convert it, complain, ask again", is exactly what `ask_int` replaces. An invalid
   answer gets a short, plain message and the same question again. The end of input is an
   `InputError`, as for `input` (15.2), so a program fed a file never loops forever.
4. **Everything is ordinary text on standard output.** Prompts use the same input and output
   as `input`, so they work in any terminal, in the REPL, and with piped input in tests. No
   arrow keys, no cursor movement, no clearing the screen.

## Verified constraints (checked against source, 2026-09-28)

- **Console is written in Emerald** in `src/prelude.em` (`class Console`), with small natives
  for the color policy (`Console._color`) and `Console.plain`, routed by key in
  `Interpreter.evaluateCall`. Most of this plan can be Emerald code in the prelude too; only
  column width needs a new native (`Console._width`).
- **Unicode data is generated, not hand-written.** `tools/unicode/fetch.sh` downloads the
  Unicode Character Database, and `tools/unicode/generate.zig` writes `src/unicode/tables.zig`
  (Unicode 17.0.0), including `extended_pictographic`. East Asian Width
  (`EastAsianWidth.txt`) and emoji presentation (`emoji/emoji-data.txt`'s
  `Emoji_Presentation`) are not there yet; they are added through the same pipeline.
- **Strings are grapheme-indexed** (`src/strings.zig` `characters`), so a width function can
  walk graphemes and give each one a width.
- **`Csv.encode` is a checker special case** (`Checker.csvEncodeIssue`, `typeOfTypedDecode`
  and its encode counterpart; `Interpreter.csvEncodeRecords`, `csvEncodeCell`) that accepts a
  `List` of plain structs whose public fields each fit one cell. The typed `Console.table`
  accepts exactly that set of types and should share this code rather than copy it.
- **Conformance can feed input.** A case's `.input` file is its standard input
  (`conformance/run/first-program.input`), so prompts are tested end to end.
- **The style check** in `src/conformance.zig` requires `else`, `catch`, and `finally` on
  their own lines and every `examples/` file to be formatter-clean. New examples must pass it.
- **A run checks only the prelude bodies its program reaches.** New prelude code costs nothing
  for programs that do not use it. Measure anyway with `tools/startup-benchmark.py`, and add
  `run/prelude-reach` lines.

## Proposed API

All of it is in `Console`, in the `Emerald` namespace.

```emerald
# Layout
Console.table(rows, header: List[String] = []): String       # decision 2
Console.panel(text: String, title: String? = nothing, color: Console.Color? = nothing): String

# Prompts
Console.ask(question: String, default: String? = nothing): String
Console.ask_int(question: String, minimum: Int? = nothing, maximum: Int? = nothing): Int
Console.ask_float(question: String, minimum: Float? = nothing, maximum: Float? = nothing): Float
Console.confirm(question: String, default: Bool? = nothing): Bool
Console.choose(question: String, options: List[String]): String                  # decision 6
Console.choose_many(question: String, options: List[String]): List[String]
```

### `Console.table`

- `rows` is either a `List[List[String]]` or a `List` of a plain struct (decision 2).
  - **Text rows** are shown as given, left-aligned. `header:` adds a header row with a rule
    under it. Every row, and the header when there is one, must have the same number of cells;
    otherwise it raises a `RuntimeError` naming the row: `row 3 has 2 cells, but row 1 has 3`.
  - **Struct rows** take their header from the public field names, in declaration order, as
    `Csv.encode` does. `Int` and `Float` columns are right-aligned, and everything else is
    left-aligned. A value is shown as `print` would show it, and `nothing` is an empty cell.
    `header:` is not accepted with struct rows; the checker says so.
- Each cell has one space of padding on each side. A cell containing a line break is a
  `RuntimeError` naming its row and column, since a cell is one line.
- An empty list gives an empty string, or just the header when there is one.

### `Console.panel`

- A box around `text`, with one space of padding, sized to its widest line. `\n` separates
  lines; a final line break does not add an empty line.
- `title:` is set into the top border: `┌─ Level 2 ───┐`. A title wider than the text widens
  the box.
- `color:` colors the border (and title) with the execution's color policy, like every other
  Console style. The text keeps whatever styling it already has.
- A panel's text may itself be a table or another panel.

### Prompts

- Each prompt writes its question and one space, then reads a line as `input` does.
  Surrounding spaces are removed from the answer.
- **`ask`** returns the answer text. An empty answer asks again, with `Please enter an answer.`,
  unless there is a `default`: then the question shows it, `What's your name? [Ada] `, and an
  empty answer returns it.
- **`ask_int` and `ask_float`** convert with `to_int_maybe` and `to_float_maybe` (9.4). A
  non-number says `Please enter a whole number.` or `Please enter a number.`; a number out of
  range says `Please enter a whole number from 0 to 150.` (or `at least 0`, or `at most 150`,
  when only one bound is given). The question is repeated after each message.
- **`confirm`** shows `(y/n)`, and accepts `y`, `yes`, `n`, and `no` in any capitalization.
  With `default: true` it shows `(Y/n)` and an empty answer is `true`, and likewise for
  `false`. Anything else says `Please answer y or n.`
- **`choose`** prints the question and the numbered options, then asks `Choose 1-3: `. It
  returns the chosen option's text. A number out of range or a non-number says
  `Please enter a number from 1 to 3.`
- **`choose_many`** asks `Choose any of 1-3, separated by commas, or press Enter for none: `.
  It accepts numbers separated by commas and/or spaces, ignores repeats, and returns the
  chosen options in the order they are listed, not the order typed.
- **Messages** are written with `Console.yellow` so they stand out when color is on and read
  plainly when it is off. The numbered options are plain.
- **Bad arguments** raise a `RuntimeError` before anything is printed: `choose` or
  `choose_many` with no options, or `minimum` greater than `maximum`.
- **End of input** while a prompt waits raises `InputError`, as `input` does.

## Decisions

Each has a recommendation; the user decides.

1. **Widgets return a `String` (recommended),** matching the styling helpers, so they compose
   (a table inside a panel) and can be written to a file. Alternative: widgets print directly,
   saving one `print(...)` per use but losing both.
2. **`Console.table` accepts a list of the program's own structs as well as text rows
   (recommended).** `print(Console.table(scores))` is the beginner's case, and it needs no
   string conversion per cell. It is typed by the checker the way `Csv.encode` is, with the
   same rule for which fields fit a cell. Alternative: text rows only, so every program
   converts its values to `String` first.
3. **Width in terminal columns, from Unicode data (recommended).** East Asian Wide and
   Fullwidth characters and emoji-presentation graphemes take two columns; zero-width and
   combining characters none; Console's own SGR sequences none. This needs East Asian Width
   and emoji data added to the generated Unicode tables. Alternative: count graphemes, which is
   right for English and misaligns any table containing Chinese, Japanese, Korean, or emoji.
4. **Borders use Unicode box-drawing characters only (recommended):** `┌─┬┐│├┼┤└┴┘`, which
   every current terminal, Windows Terminal and the classic Windows console included, draws.
   Alternative: an `ascii: Bool` option for `+-|` borders, one more choice a beginner has no
   reason to make.
5. **Six prompts: `ask`, `ask_int`, `ask_float`, `confirm`, `choose`, and `choose_many`
   (recommended),** each asking again until the answer is usable. `ask_int` and `ask_float`
   take bounds but no default, since a number prompt's empty answer is almost always a slip.
   Alternative: `ask` alone, with conversion left to the program, which is the loop students
   write badly most often.
6. **`choose` returns the option's text (recommended),** so `if level == "Hard"` reads
   naturally. Alternative: the option's index, which suits looking something up in a parallel
   list but makes the common case harder to read.

## Slices

Each slice ends with the full validation below passing, and one commit or a short series of
commits.

### Slice 1: Column width

- Extend `tools/unicode/fetch.sh` and `generate.zig` with `EastAsianWidth.txt` and
  `emoji/emoji-data.txt`, and regenerate `src/unicode/tables.zig` (still Unicode 17.0.0).
- Add a width function over graphemes to `src/unicode.zig`:
  - 2 for a grapheme whose first scalar is East Asian Wide or Fullwidth, or that has emoji
    presentation (an `Emoji_Presentation` scalar, or any Extended_Pictographic scalar followed
    by U+FE0F);
  - 0 for a grapheme made only of controls or format characters;
  - 1 otherwise.
  - Complete SGR sequences (`ESC [ … m`) count as 0, using the same recognizer as
    `Console.plain`.
- Expose it as the native `Console._width(text: String): Int`. It stays private to the prelude.
- Unit tests in Zig for ASCII, CJK, Hangul, emoji with and without VS16, a family emoji (one
  grapheme, width 2), combining marks, and styled text.
- Settled while building: (record here)

### Slice 2: `Console.panel` and text-row `Console.table`

- Written in Emerald in the prelude over `Console._width`.
- Conformance:
  - `run/console-layout.em`: panels with and without titles, multi-line text, a title wider
    than the text, a panel inside a panel, text tables with and without headers, CJK and emoji
    cells, and styled cells lining up (with color off, the default in conformance), and each
    error.
  - `color/console-layout.em`: a colored border with styling forced on.
- Settled while building: (record here)

### Slice 3: Struct-row `Console.table`

- Checker special case sharing `Csv.encode`'s field rule; the interpreter turns the records
  into rows (sharing `csvEncodeRecords`'s field walk) and uses slice 2's layout, with numeric
  columns right-aligned.
- A diagnostics case for a struct with a field that cannot be a cell, and one for `header:`
  given with struct rows.
- Settled while building: (record here)

### Slice 4: Prompts

- The six prompts, in Emerald in the prelude over `input`/`input_maybe`.
- Conformance with `.input` files:
  - valid answers for each prompt;
  - every invalid answer and its message, then a valid one;
  - defaults, bounds, and `choose_many` with repeats, spaces, and none;
  - end of input as an `InputError` in `runtime-errors/`;
  - each bad-argument error.
- Settled while building: (record here)

### Slice 5: Documentation and integration

- `docs/library/console.md` gains Layout and Prompts sections; `inventory.md` updates its row.
- `examples/console.em` grows into a small quiz or game that uses a panel, a struct table, and
  the prompts. It must still run under `tools/check-doc-examples.sh`, which feeds blank lines,
  so it has to survive empty answers, for example by giving `confirm` a default.
- Rewrite-context 15.6 records the settled design and decisions, and 15.7 and 24 mark the
  widgets and prompts done.
- A valid-program fuzz template for `table` and `panel`, `run/prelude-reach` lines, the startup
  comparison, and the handoff and journal.
- Settled while building: (record here)

## Validation

Every slice must pass, on the pinned Zig 0.16.0 with `-j1`:

- Debug and ReleaseSafe `zig build test -j1`;
- `zig build -j1`;
- `bash tools/check-doc-examples.sh`;
- `zig fmt --check` on changed Zig files;
- `git diff --check`;
- Windows and macOS cross-builds with `--prefix` outside `zig-out`, so the native binary is
  not overwritten.

Slice 1 also runs `zig build unicode-conformance` against the downloaded database. Slice 5 also
runs an alternating ReleaseSafe startup comparison against `main` with
`tools/startup-benchmark.py`, showing no measurable cost for a program that does not use these
functions.

## Out of scope

These are deliberately not in this plan:

- arrow-key menus, spinners, progress bars that redraw, clearing the screen, and anything else
  needing raw-mode input or cursor control (a full-screen terminal library, parked in 24);
- wrapping or truncating to the terminal's width, which Emerald does not know when output is
  redirected;
- column alignment options, cell styling options, and border styles beyond the one default;
- password input with hidden typing, which needs terminal control.

The same width function could later place diagnostic carets correctly under wide characters;
that is a separate change.
