# Console

`Console` is the first official platform library (15.6, 24): terminal styling of individual
strings. A styled value is an ordinary `String` carrying ANSI SGR escape sequences, so
`print`, interpolation, assignment, and `+` all work on it unchanged; style at the output
boundary (`print("Result: #{Console.green(status)}")`) rather than in stored data, since the
escape bytes count toward `count`, indexing, slicing, and searching, and travel with the
string to a file. Run [`conformance/color/console-style.em`](../../conformance/color/console-style.em)
for exact sequences with styling forced on, and
[`conformance/run/console-style-off.em`](../../conformance/run/console-style-off.em) for every
helper's behavior with styling off; [`examples/console-style.em`](../../examples/console-style.em)
tours the styling, and [`examples/console.em`](../../examples/console.em) is a small program
that uses layout and prompts too.

## Color helpers

```emerald
Console.black(text: String) -> String
Console.red(text: String) -> String
Console.green(text: String) -> String
Console.yellow(text: String) -> String
Console.blue(text: String) -> String
Console.magenta(text: String) -> String
Console.cyan(text: String) -> String
Console.white(text: String) -> String

Console.bold(text: String) -> String
Console.dim(text: String) -> String
Console.italic(text: String) -> String
Console.underline(text: String) -> String
```

Each helper wraps `text` in one SGR layer and its matching close code, and returns `text`
unchanged when the execution's color policy (below) is off. There is no persistent
foreground/background state to set and forget, unlike a C#-style console API: every call
styles exactly the string it is given.

## `Console.style`

```emerald
Console.style(
    text: String,
    foreground: Console.Color? = nothing,
    background: Console.Color? = nothing,
    bold: Bool = false,
    dim: Bool = false,
    italic: Bool = false,
    underline: Bool = false
) -> String
```

The general form behind every helper above, and the only way to reach a background color or
one of the eight bright foreground/background colors. `Console.Color` is a nested enum
(14.3) with sixteen values: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
`white`, and `bright_black` through `bright_white`; `nothing` for `foreground`/`background`
means the terminal's own default. Requested attributes each apply as their own layer,
innermost first, in this order: foreground, background, bold, dim, italic, underline.
`Console.style(text)` with no options, and every case with the color policy off, returns
`text` unchanged.

Wrapping a string that itself contains a styled span nests correctly: closing the inner span
reopens the outer style rather than falling back to the terminal's default, and a bare reset
(`ESC[0m`) found inside the input also reopens every enclosing layer around it. Bold and dim
share one close code (`22`), so nesting one inside the other is the case most worth checking
by hand when composing styles.

## `Console.plain`

```emerald
Console.plain(text: String) -> String
```

Removes every complete SGR sequence (`ESC`, `[`, digits and/or `;`, then `m`) from `text`,
regardless of the color policy. Other terminal control sequences, bare `ESC` characters, and
incomplete or malformed sequences are left untouched. `plain` undoes Console's own styling; it
is not a general terminal-output sanitizer, and does not attempt to strip arbitrary or
adversarial escape sequences.

## The color policy

Whether any of the above actually emits ANSI escapes is one policy per execution, owned by
the runtime rather than a mutable Emerald-level switch — no Emerald program can turn styling
on or off partway through a run, so a message is never half-styled by a policy change while
it is being built. `emerald run` and `emerald test` resolve it in this order, highest
precedence first:

1. `--color=always` or `--color=never` on the command line.
2. `NO_COLOR` present and non-empty: off.
3. `FORCE_COLOR` present, non-empty, and not `0`: on.
4. `TERM=dumb`: off.
5. Otherwise, on only when standard output is a terminal that supports ANSI escapes.

`--color=auto` (the default) falls through to steps 2 through 5. `emerald repl` follows the
same steps 2 through 5 automatically; it has no `--color` flag of its own. On Windows, an
ordinary console needs a one-time request to process ANSI escapes at all, which step 5 makes
automatically; forced styling (`--color=always`, `FORCE_COLOR`) never touches the console, so
it is correct for redirected output — a file, a pipe, CI logs — where there is no console to
configure and the reader on the other end interprets the escapes itself.

## Layout

### Console.table(rows: List[List[String]], header: List[String] = []) -> String

Text rows are shown left-aligned. Each cell has one space of padding, and borders use Unicode
box-drawing characters. `header:` adds a header and a rule below it. Every row must have the
same number of cells, and cells cannot contain line breaks; malformed rows raise a
`RuntimeError` naming their row and column. Data rows are numbered from 1; a header is
named separately, as in `the header has 1 cell, but row 1 has 2 cells`.
Width is measured in terminal columns, so CJK
characters and emoji occupy two columns while styling occupies none. Tabs and other control
characters occupy no columns, so replace a tab with spaces before laying out text that has one. An empty list returns an
empty string, or just the header when one is supplied.

The same method accepts a list of plain structs. Public fields become the header in declaration
order, numeric columns (and their headers) are right-aligned, and values display as `print` would; `nothing` is an
empty cell. A struct-row table cannot also receive `header:`. See
[`conformance/run/console-struct-table.em`](../../conformance/run/console-struct-table.em).

### Console.panel(text: String, title: String? = nothing, color: Console.Color? = nothing) -> String

Returns a box around one or more lines, with one space of padding and a width based on the
widest terminal-column line. A title is placed in the top border, and `color:` styles only the
border and title. A final newline does not create an extra empty row. Panels and tables are
ordinary strings and can be nested. See [`conformance/run/console-layout.em`](../../conformance/run/console-layout.em).

## Prompts

### Console.ask(question: String, default: String? = nothing) -> String

Writes the question and a space, trims surrounding whitespace from the answer, and repeats
after `Please enter an answer.` when the answer is empty. With a default, it is shown in
brackets and an empty answer returns it.

### Console.ask_int(question: String, minimum: Int? = nothing, maximum: Int? = nothing) -> Int

Reads a whole number and repeats with a plain validation message for malformed or out-of-range
answers. Bounds are inclusive; supplying a minimum greater than the maximum raises a
`RuntimeError` before printing.

### Console.ask_float(question: String, minimum: Float? = nothing, maximum: Float? = nothing) -> Float

The floating-point counterpart to `ask_int`, with inclusive bounds and `Please enter a number.`
for malformed answers. `NaN` and the infinities are not accepted as answers.

### Console.confirm(question: String, default: Bool? = nothing) -> Bool

Accepts `y`, `yes`, `n`, or `no` in any capitalization. A default changes the prompt to `(Y/n)`
or `(y/N)` and makes an empty answer select that value; otherwise an invalid answer says
`Please answer y or n.` and repeats.

### Console.choose(question: String, options: List[String]) -> String

Prints numbered options once and asks `Choose 1-N: `. It returns the selected option's text
and, for a malformed or out-of-range answer, says `Please enter a number from 1 to N.` and asks
`Choose 1-N: ` again without repeating the options. An
empty option list raises a `RuntimeError` before printing.

### Console.choose_many(question: String, options: List[String]) -> List[String]

Accepts option numbers separated by commas and/or spaces. Repeated indexes are ignored, and
the returned options follow the list's order rather than typing order. Enter alone returns an
empty list. Invalid input says `Please enter numbers from 1 to N.` and repeats; an empty option
list raises a `RuntimeError` before printing.

All prompt retry messages use `Console.yellow`, so they are colored only when the execution's
color policy enables styling. End of input raises `InputError`, and its message names the prompt:
`` `Console.ask` reached the end of the input ``. See
[`conformance/run/console-prompts.em`](../../conformance/run/console-prompts.em) and
[`examples/console.em`](../../examples/console.em).
