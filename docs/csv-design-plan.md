# CSV: design and implementation plan

Status: in progress, 2026-09-28. The user accepted every recommendation, including decision 2:
`Csv.decode` and `Csv.encode` are typed by the checker, as JSON's are. Slices 1–3 are complete;
slice 4 is next.
Rewrite-context 15.7
lists CSV as a small library that pairs with `File`. This plan sets out the API, how a
table of text becomes the program's own types, errors, and the order of work. The executor
makes the remaining judgement calls within a slice, and records each one under that slice's
"Settled while building" note. At the start of each slice, reread `git status`, the recent
`git log`, and docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally, and a mistake in the data
should say which line and which column it is in.

```emerald
# Read a spreadsheet export into the program's own type.
struct Score {
    const name: String
    const points: Int
    const team: String? = nothing
}

const scores = Csv.decode(File.read("scores.csv"), as: List[Score])
for score in scores {
    print("#{score.name}: #{score.points}")
}

# Save the program's own values as a spreadsheet can open them.
File.write("results.csv", Csv.encode(scores))

# A table whose columns are not known ahead of time, read by column name.
for row in Csv.parse_records(File.read("survey.csv")) {
    print(row["answer"].or("(no answer)"))
}

# Rows as plain lists of text, header and all.
const rows = Csv.parse(File.read("grid.csv"))
print(rows[0])
print(Csv.format([["x", "y"], ["1", "2"]]))
```

`scores.csv`:

```text
name,points,team
Ada,120,red
Grace,95,
"Hopper, Grace",88,blue
```

## Principles

1. **The same two ways in as JSON.** A program that knows its columns names a type and gets
   its own values back (`Csv.decode(text, as: List[Score])`), checked in one step. A program
   that does not reads text by column name or position. The typed path reuses JSON's
   checker special case (15.9) and its rules: generated constructors, defaults, optionals,
   and private fields never read or written.
2. **Errors say where.** A CSV file is edited by hand and exported from spreadsheets, so
   every error names the line, and for a value, the column: `line 4, column "points":
   expected a whole number, found "twelve"`.
3. **What spreadsheets write, read as they mean it.** RFC 4180 quoting (commas, quotes, and
   line breaks inside a quoted field; `""` for a quote), Windows and Unix line endings, and a
   leading byte-order mark, which Excel adds. A final line break does not start an empty row.
4. **Nothing surprising on the way out.** A field is quoted only when it must be; a `Float`
   stays a `Float` (`2.0`); columns follow the struct's declaration order.

## Verified constraints (checked against source, 2026-09-28)

- **`Json.decode(text, as: Type)` is a checker special case** (`Checker.typeOfJsonDecode`,
  `jsonDecodeIssue`), with the parser reading `as:` as a type only in a call written
  `Json.decode` (`Parser.isJsonDecodeCallee`). `Csv.decode` needs the same, and the parser
  test must accept `Csv.decode` and `Emerald.Csv.decode` too, and nothing else.
- **`Json.encode` is typed specially** (`typeOfJsonEncode`, `jsonEncodeIssue`); `Csv.encode`
  is the same shape with a narrower rule.
- **JSON's decoding already handles** a struct's generated constructor, defaults that win
  over `nothing`, optionals, private fields that take their defaults, enums by value name,
  and `Date`, `Time`, `DateTime`, and `Instant` through their `parse_maybe`. CSV's typed path
  should share that code rather than copy it.
- **`String.to_int_maybe` and `to_float_maybe`** parse strictly and accept surrounding
  spaces (9.4), which is the right rule for a cell.
- **A run checks only the prelude bodies its program reaches** (startup plan, slice 2). A
  native that calls Emerald code, as typed decoding calls `Date.parse_maybe`, relies on the
  target type being reached; it is, through the call's result type. Keep `run/prelude-reach`
  passing, and add a CSV line to it.
- **Python's `csv` module** can serve as a differential reference for the parser, as
  Python's `json` did for JSON (`tools/json/differential.py`).

## Proposed API

All in the `Emerald` namespace.

```emerald
# Reading
Csv.parse(text: String, separator: String = ","): List[List[String]]
Csv.parse_records(text: String, separator: String = ","): List[Dict[String, String]]
Csv.decode(text: String, as: Type, separator: String = ","): Type      # decision 2

# Writing
Csv.format(rows: List[List[String]], separator: String = ","): String
Csv.encode(records, separator: String = ","): String                    # decision 2

class CsvError extends RuntimeError {
    const line: Int?          # the line the problem is on, when there is one
}
```

- **`parse`** gives every row, the header included, as lists of text. Rows may differ in
  length; nothing is checked beyond the quoting.
- **`parse_records`** uses the first row as column names and gives each later row as a
  `Dict` from column name to text, in column order. A row with more or fewer fields than
  the header is a `CsvError` naming the line and both counts. A repeated or empty column
  name is a `CsvError` naming it.
- **`decode`** is `parse_records` into the program's type. `as:` is a `List` of a plain
  struct, whose fields are matched to columns by name. Extra columns are ignored.
- **`format`** writes rows as given; **`encode`** writes a header of field names, then one
  row per value.
- **`separator`** is one character: `","` by default, `";"` for the spreadsheets that use it,
  or `"\t"` for tab-separated files. Anything else is a `CsvError`.
- **Line endings:** reading accepts `\n` and `\r\n`; writing uses `\n` (decision 4).

## Decisions

All five were accepted as recommended on 2026-09-28.

1. **Name: `Csv`,** matching `Json` and `Http`. Alternative: `CSV`.
2. **Typed reading and writing through the checker, as JSON does (the main decision).**
   `Csv.decode(text, as: List[Score])` and `Csv.encode(scores)` are typed specially, with a
   rule narrower than JSON's, since a cell holds one piece of text. A field may be `String`,
   `Int`, `Float`, `Bool`, an enum, `Date`, `Time`, `DateTime`, `Instant`, or an optional of
   one of those; a struct with any other field (a `List`, a nested struct, a `Json`) is
   refused at check time, naming the field. Alternative: only `parse`, `parse_records`, and
   `format`, leaving every conversion to the program, which is exactly the tedium the
   typed path spares a beginner.
3. **An empty cell means "no value".** For an optional field it is `nothing`; for a field
   with a default it takes the default; for a `String` field it is `""`; for any other field
   it is a `CsvError` (`line 3, column "points": this cell is empty`). Spreadsheets leave
   cells blank far more often than they write anything that means "none". Alternative: an
   empty cell is always an error unless the field is optional.
4. **Writing uses `\n` line endings,** as most modern tools do; every spreadsheet reads them.
   Alternative: RFC 4180's `\r\n`, which Python's `csv` module writes by default.
5. **`Bool` cells accept `true` and `false` in any capitalization,** since spreadsheets write
   `TRUE`; writing uses `true` and `false`. Alternative: accept only lowercase, as Emerald
   writes them.

## Errors

`CsvError` extends `RuntimeError`, with `line` set whenever a line is known. Messages to
match in wording:

| Failure | Message |
| --- | --- |
| Unclosed quote | `line 7: a quoted field that starts here never closes` |
| Text after a closing quote | `line 2: a quoted field must end at a separator or the end of the line, not "x"` |
| Row length (records, decode) | `line 5 has 4 fields, but the header has 3` |
| Missing column (decode) | `there is no column "points"; the columns are "name" and "team"` |
| Wrong value (decode) | `line 4, column "points": expected a whole number, found "twelve"` |
| Empty cell (decode) | `line 3, column "points": this cell is empty` |
| Bad separator | `a separator must be one character, not ";;"` |
| Repeated column | `the header names the column "name" twice` |

Missing columns for a field that has a default or is optional are not errors.

## Implementation approach

- **A native layer, `src/Csv.zig`,** independent of the interpreter, as `src/Json.zig` is: a
  single-pass parser over the text (BOM, quoting, both line endings, the separator), giving
  rows of fields with each row's line number, and a writer that quotes a field only when it
  contains the separator, a quote, or a line break, or starts or ends with a space.
- **The prelude** holds `Csv` (type-level functions over positional natives in
  `Interpreter.callCsv`) and `CsvError`.
- **The typed path** generalizes JSON's checker special cases and decoder so both share the
  struct and field rules; CSV adds its narrower field rule and its conversions from text.
- **Startup:** new prelude types are only checked when a program reaches them, so CSV costs
  nothing to programs that do not use it. Confirm with `tools/startup-benchmark.py` against
  the build before.

## Slices

Each slice is runnable and committed on its own, with AGENTS.md's validation and the
rewrite-context text written in the same change.

1. **The parser and writer, without Emerald.** `src/Csv.zig` with Zig unit tests for every
   quoting case and error, and `tools/csv/differential.py` checking the parser against
   Python's `csv` module on generated tables, including separators, quoted separators,
   quotes, line breaks inside fields, and both line endings.

   **Settled while building (2026-09-28):** A separator is one Emerald character, measured as
   one grapheme rather than one byte or code point. The parser compares its UTF-8 bytes and
   preserves each row's physical starting line. The differential tool ran 3,000 generated
   cases (seed 1) against Python's reader with no differences.
2. **Untyped reading and writing.** `Csv.parse`, `parse_records`, `format`, and `CsvError`,
   with conformance for each and for every text error in the table.

   **Settled while building (2026-09-28):** An empty document has no records. A blank or
   repeated header is on line 1, so `CsvError.line` is set even though the approved messages do
   not repeat that line number. A blank header says `the header has an empty column name`.
3. **`Csv.decode`.** The checker special case (parser `as:` recognition included), the field
   rule, empty cells, missing and extra columns, and every value error, with diagnostics
   conformance for refused field types.

   **Settled while building (2026-09-28):** CSV cells are converted to primitive JSON values,
   then passed through JSON's existing recursive decoder for constructors, defaults, optionals,
   private fields, enums, and date/time parsing. A missing column for an optional or defaulted
   field is omitted so the shared decoder supplies its ordinary value; a struct's unknown CSV
   columns are ignored.
4. **`Csv.encode`.** The checker special case and the writer for records, with a round trip
   through `decode`.
5. **Documentation and integration.** `docs/library/csv.md`, an inventory row, an example, a
   new rewrite-context section with decision rows in 22, 15.7 updated, a fuzz template, and a
   line in `run/prelude-reach`. Then remove this plan, as the
   JSON and HTTP plans were removed, and point any references at the new section.

## Working notes for the executor

These come from reviewing the JSON and HTTP milestones.

- **Share JSON's typed machinery; do not copy it.** The JSON review fixed six defects in it
  (argument order, recursive structs, defaults overwriting given values, private fields, and
  more). A second copy would need the same fixes.
- **Bind arguments by name, never by position,** in every native; `decode` takes `as:` and
  `separator:` in any order.
- **Test every branch of behavior:** each parameter given, omitted, and wrong; each field kind
  present, empty, missing, and malformed.
- **Check every example's output against the built binary** before writing it into docs or
  expectations.
- **Write a commit message body** for each slice: what it adds, what was settled, and the
  validation run.
- **Build with `-j1`** on the 7 GB development machine when another build may be running;
  parallel builds have run it out of memory.
- **Keep AGENTS.md's handoff rule:** update docs/handoff.md before each commit, and do not
  push unless the user says so.

## Out of scope for this milestone

Streaming very large files row by row, guessing the separator, other character encodings
than UTF-8, a `Csv.Table` type, writing `Dict` records, formulas, and multi-line headers.
Each can be revisited with a real program that needs it (24).

## Risks

- **Real files are messier than RFC 4180.** Spreadsheets vary in quoting and blank lines;
  the differential against Python's `csv` module and a few hand-made spreadsheet exports
  are the check.
- **Generalizing JSON's typed code** could disturb JSON. Its conformance must pass unchanged
  after slice 3.
