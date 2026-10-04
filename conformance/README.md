# Conformance suite

These cases are written in Emerald, and their expectations are Emerald behavior. They are
deliberately not Zig unit tests: section 19.6 of the rewrite context requires language
semantics to be defined once in backend-neutral tests, and section 23 requires an
end-to-end behavioral test for anything a future backend could inherit incorrectly from its
host. A replacement backend is acceptable only when it passes these same files unchanged.

Run them with `zig build test`. The runner is [`src/conformance.zig`](../src/conformance.zig).
The test suite also formats and reparses every `.em` file under `run/`, including
project files, to catch formatting that breaks valid syntax. No cases are excluded.

## Layout

| Directory | Assertion |
| --- | --- |
| `lexical/` | The program tokenizes with no diagnostics. |
| `diagnostics/` | `check` reports exactly the text in its `.expected` file. |
| `run/` | The program runs and prints exactly its `.expected` file. |
| `color/` | The program runs with Console ANSI styling forced on. |
| `http/` | The program runs against a local HTTP server; its base address is `Program.arguments[0]`. |
| `local-zone/` | The program runs with `TimeZone.local` set to `EST5EDT`, the United States' Eastern rules, so changes of clocks are the same everywhere. |
| `runtime-errors/` | The program runs, then fails with exactly its `.expected` file. |
| `format/` | `emerald format` produces exactly its `.expected` file, and formatting that output again changes nothing. |
| `repl/` | A `.input` session produces exactly its `.expected` transcript, on 50 consecutive runs. |
| `lsp/` | A marked document produces exactly the selected framed LSP reply, on 50 consecutive runs. |

A case is usually one `.em` file. A directory holding a `main.em` is one case too — a
whole project, per section 14.1 of the rewrite context — and the files inside it are not
cases of their own. Its `.expected` sits beside the directory rather than inside it, so
`run/project/` is judged by `run/project.expected`.

REPL cases are `.input` files, not `.em` programs. Their expectations contain
the greeting, prompts, output, and diagnostics, without echoing the typed input.
They are compared byte-for-byte on 50 consecutive runs. The final prompt's space
is meaningful; `.gitattributes` exempts only these golden files from trailing-space checks.

LSP documents mark one request position with `/*cursor*/`, which is removed before
`didOpen`. The server receives real framed `initialize`, `didOpen`, and request messages.
The request is `textDocument/completion` unless a `.request` file names another method.
For `textDocument/codeAction`, the request forwards the actual didOpen diagnostics
in its context and uses an empty range at the marker. Its full reply is pretty-printed
JSON in `.expected`; incidental didOpen diagnostics are not otherwise part of that reply.
The case's absolute URI in workspace edits is normalized to `file:///document.em`.
A directory with `main.em` is a project case, as above.
Every case runs 50 consecutive times, including under CI's testing allocator.

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

The command line labels some diagnostics with a code, such as `[E4001]`, which the suite does
not compare; remove it from a `diagnostics/` expectation (`sed -i -E 's/: \[E[0-9]+\] /: /'`).

A `format/` case's `.em` file is its own input; write it exactly as you want the formatter to
leave it if it is already canonical, or deliberately un-canonically if you want to see it
rewritten. Either way, generate its `.expected` the same way:

```bash
../zig-out/bin/emerald format format/your-case.em
cp format/your-case.em format/your-case.expected
git checkout format/your-case.em # if it was meant to start un-canonical
```

A project case is a directory with a `main.em` in it, and is generated the same way
through that file:

```bash
../zig-out/bin/emerald run run/your-project/main.em > run/your-project.expected
```

A `run/` or `runtime-errors/` case whose program calls `input` reads from a `.input` file
beside it, such as `run/first-program.input`; without one, its input is empty. Generate
its expectation with that file on standard input:

```bash
../zig-out/bin/emerald run run/your-case.em < run/your-case.input > run/your-case.expected
```

Then read what was generated before committing it. A golden file that was never read only
records what the compiler did, not what it should do. Check the line and column, the width
of the underline, and whether the message and its correction would actually help the person
who hit it — section 17 treats diagnostic text as part of the product, not as debug output.

## Coverage so far

Encoding, lexical structure, syntax, name resolution, type checking, definite assignment,
arithmetic, comparison, bindings, conditionals, loops, functions, lists and their value
semantics, dictionaries and sets with their insertion order and key rules, tuples and their
unpacking, strings and their Unicode behavior, optionals and narrowing, input, structs with
required fields and their value semantics, assignment through a path of indices and struct
fields, custom constructors and the readiness of `self`, instance methods and which of them change `self`, computed properties, type-level functions and fields with their lazy setup, private members, method values, classes as shared objects, inheritance with overrides and abstract classes, type tests and `type_name`, traits, `Self`, annotated arithmetic operators and `Ordered` comparisons, custom equality and hashing through `Equatable`/`Hashable`, enums and `case`, nested functions, nested tuple patterns, field defaults, default parameters and named arguments, projects of several files with their namespaces, `using`, privacy and lazy module
initialization, and stack traces for runtime errors raised inside functions and across
files. Unicode's own
conformance data is checked separately, by the unit tests in `src/unicode.zig`. What
remains at runtime is what cannot be known statically: integer overflow, division by zero,
exceeding the recursion limit, an entry a dictionary does not have, and an initialization
cycle between files or between a type's fields.
