# Ledger

A small persisted personal-finance command-line program, intended as a real-program
shakedown for Emerald rather than a conformance fixture. It stores a tab-delimited journal at
`.emerald-ledger/entries.tsv` relative to the directory where it runs.

```bash
zig build run -- run examples/ledger/main.em -- add 2026-09-20 groceries -42.75 market
zig build run -- run examples/ledger/main.em -- add 2026-09-21 salary 2500.00 September-pay
zig build run -- run examples/ledger/main.em -- list
zig build run -- run examples/ledger/main.em -- summary 2026-09
zig build run -- run examples/ledger/main.em -- category groceries
zig build run -- run examples/ledger/main.em -- import bank-export.tsv
```

The date is intentionally a lightly validated `YYYY-MM-DD` string: this example does not
invent a date-time library. Categories and notes cannot contain tabs or line breaks because
they are fields in the deliberately simple storage format.

`import` reads the same tab-delimited format incrementally and skips transactions already in
the journal (or repeated within the import) when date, category, and amount match. Notes are
commentary and intentionally do not make an imported transaction distinct.
