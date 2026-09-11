# Conformance suite

These cases are written in Emerald, and their expectations are Emerald behavior. They are
deliberately not Zig unit tests: section 19.6 of the rewrite context requires language
semantics to be defined once in backend-neutral tests, and section 23 requires an
end-to-end behavioral test for anything a future backend could inherit incorrectly from its
host. A replacement backend is acceptable only when it passes these same files unchanged.

Run them with `zig build test`. The runner is [`src/conformance.zig`](../src/conformance.zig).

## Layout

| Directory | Assertion |
| --- | --- |
| `lexical/` | The program tokenizes with no diagnostics. |
| `diagnostics/` | `check` reports exactly the text in its `.expected` file. |
| `run/` | The program runs and prints exactly its `.expected` file. |
| `runtime-errors/` | The program runs, then fails with exactly its `.expected` file. |

Cases run in sorted order, and every case runs even after one fails, so a single run
reports the whole picture.

`lexical/` exists because the lexer accepts far more of the language than the parser does
yet. Those cases protect real lexical rules now, and graduate to `run/` as the stages
behind them land.

## Adding a case

Add a `.em` file to the directory matching what you want to assert. Every directory except
`lexical/` also needs a `.expected` file beside it holding the exact output. Generate it by
running the compiler from this directory, so the paths in the expected text stay relative
and machine-independent:

```bash
cd conformance
../zig-out/bin/emerald check diagnostics/your-case.em 2> diagnostics/your-case.expected
../zig-out/bin/emerald run run/your-case.em > run/your-case.expected
../zig-out/bin/emerald run runtime-errors/your-case.em 2> runtime-errors/your-case.expected
```

Then read what was generated before committing it. A golden file that was never read only
records what the compiler did, not what it should do. Check the line and column, the width
of the underline, and whether the message and its correction would actually help the person
who hit it — section 17 treats diagnostic text as part of the product, not as debug output.

## Coverage so far

Encoding, lexical structure, syntax, name resolution, type checking, definite assignment,
arithmetic, comparison, bindings, and conditionals. What remains at runtime is what cannot
be known statically: integer overflow, division by zero, and reading a name the checker
could not prove assigned.
