# Csv

`Csv` reads and writes UTF-8 comma-separated text: spreadsheet exports, small saved tables,
and interchange files. Use typed `decode` and `encode` when the columns are your program's own
record type; use `parse` and `parse_records` when the shape is only known at runtime. Run
[`examples/csv.em`](../../examples/csv.em) for both paths, and see
[`conformance/run/csv-untyped.em`](../../conformance/run/csv-untyped.em),
[`conformance/run/csv-decode.em`](../../conformance/run/csv-decode.em), and
[`conformance/run/csv-encode.em`](../../conformance/run/csv-encode.em) for focused coverage.

CSV text accepts a leading UTF-8 byte-order mark, Unix (`\n`) and Windows (`\r\n`) line
endings, quoted separators and line breaks, and doubled quotes (`""`) inside a quoted field.
The default separator is `","`; every operation accepts any one-grapheme separator such as
`";"` or `"\t"`.

```emerald
struct Score {
    const name: String
    const points: Int
    const team: String? = nothing
}

const scores = Csv.decode("name,points,team\nAda,120,red\nGrace,95,", as: List[Score])
print(Csv.encode(scores))
```

## Csv.parse(text: String, separator: String = ",") -> List[List[String]]

Reads every row as a list of text fields, including a header when the text has one. Rows may
have different lengths; `parse` does not give columns special meaning. An empty document gives
an empty list, and a trailing line break does not add a spurious empty row.

## Csv.parse_records(text: String, separator: String = ",") -> List[Dict[String, String]]

Uses the first row as column names and returns each later row as a text record. The header's
names become dictionary keys in their source order. A header cannot have a blank or repeated
name, and every data row must have exactly as many fields as the header. An empty document has
no records.

## Csv.decode(text: String, as: Type, separator: String = ",") -> Type

Reads known columns into `List[Record]`, where `Record` is a plain struct with its generated
constructor. A public field can be `String`, `Int`, `Float`, `Bool`, an enum, `Date`, `Time`,
`DateTime`, `Instant`, or an optional of one of those. Columns match public field names; extra
columns are ignored. Private fields are never read and therefore need defaults.

An empty cell gives `""` to a `String`, `nothing` to an optional, and a field's declared default
when it has one. An empty cell for another required field is an error. A missing column likewise
uses a default or optional absence, or is an error. `true` and `false` are accepted in any
capitalization; output from `encode` uses lowercase.

`as:` is a type written in source, not a runtime value. That special form works only when the
call is written `Csv.decode` or `Emerald.Csv.decode`; neither `decode` nor `encode` can be kept
as a function value.

## Csv.format(rows: List[List[String]], separator: String = ",") -> String

Writes text rows directly. It uses `\n` between rows and no final line break. A field is quoted
only when needed to preserve its meaning: it contains the separator, a quote, a line break, or
starts or ends with a space.

## Csv.encode(records, separator: String = ",") -> String

Writes a typed `List` of plain structs. The result begins with the public field names in
declaration order, then one row per record; an empty typed list still produces that header.
Private fields are never written. The field vocabulary is the same as `decode`; absent optionals
write an empty cell, enums write their value names, and date/time values use their ordinary ISO
text. `Float` keeps Emerald's normal spelling, so `2.0` stays `2.0`.

The first argument is checked at each call because Emerald has no one written type that means
"a list of CSV records." A list with an unsupported field, such as `List[String]` inside a
record, is a checking error before the program runs.

## CsvError

`CsvError` extends `RuntimeError` and has `line: Int?`. Parsing and header/row-shape failures
name the physical line when one is known. A typed conversion error names both its line and
column, for example `line 4, column "points": expected a whole number, found "twelve"`.

**Raises** `CsvError` for malformed quoting, a bad separator, a blank or duplicate record
header, a mismatched record row, a missing required column, or a cell that cannot become its
field's type. See [`conformance/run/csv-errors.em`](../../conformance/run/csv-errors.em) for
catchable parsing failures and
[`conformance/runtime-errors/csv-invalid-text.em`](../../conformance/runtime-errors/csv-invalid-text.em)
for the ordinary uncaught diagnostic.
