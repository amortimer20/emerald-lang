# Review triage

2026-10-29. Claude's triage of the eight review areas (`codebase-review-plan.md`, section 5).
**The user accepted every recommendation, D1 to D8, and the proposed order (2026-10-29).** Every reproduction was rerun on main at `d580f40` (Zig 0.17.0, macOS arm64):
the crashes and wrong answers below still reproduce. The allocation-failure crashes (area 1) and
the language-server crashes (area 2) need their harnesses and were taken from their reports.

## In numbers

| Area | Report | Raw findings |
| --- | --- | --- |
| 1. Memory | [`memory.md`](memory.md) | 8 |
| 2. Broken input | [`robustness.md`](robustness.md) | 7 |
| 3. Rules without cases | [`rules.md`](rules.md) | 23, and 84 new conformance cases that pass |
| 4. Tasks | [`tasks.md`](tasks.md) | 7 |
| 5. Platforms | [`platforms.md`](platforms.md) | 4 (2 predicted for Windows, still to run) |
| 6. Library against Python | [`stdlib.md`](stdlib.md) | 9 |
| 7. Error messages | [`errors.md`](errors.md) | 24, from a 314-program corpus (50% pass all four questions) |
| 8. Interpreter-specific behavior | [`portability.md`](portability.md) | 20 |
| Rule coverage notes | [`rule-coverage.md`](rule-coverage.md) | 4 spec problems |

About 106 raw findings, grouped below into **42 items** after merging duplicates and bundling
findings with one cause or one fix. Nothing crashed or leaked on a normal run
of any existing program; every crash needs either an unusual program, a failing allocation, or a
malformed editor request.

## A. Crashes and memory errors: fix, no decision needed

| # | Finding | From |
| --- | --- | --- |
| A1 | `group_by` panics once any group reaches five items (writes past a buffer in a release build) | 6.01, 5 |
| A2 | `check` panics when two declarations share a name and the duplicate's body calls a member | 2.1 |
| A3 | An `assert`'s interpolated message prints garbage bytes, a use after free | 3.1 |
| A4 | Five allocation-failure crashes: tuple literals, `partition`, `CsvError`, `Json`/`Csv.decode` into a struct, `Json.parse`; one cause, `createTuple`/`createStruct` take their slices even when they fail | 1.1–1.5 |
| A5 | Three allocation-failure leaks: `characters`, `split`, `List.partition` | 1.6–1.8 |
| A6 | The language server crashes: renaming a declaration named like a built-in, a position with `line` 4294967295, and expressions thousands deep (stack overflow) | 2.2–2.4 |
| A7 | The language server never answers a request with malformed params, so an editor waits forever | 2.5 |
| A8 | Output still buffered at exit, written to a closed pipe, prints a Zig stack trace | 3.7 |

## B. Wrong answers: fix, no decision needed

| # | Finding | From |
| --- | --- | --- |
| B1 | `exit(code)` inside a task exits 0; `exit()` in a child is a catchable `CancelledError` and the program keeps running; `exit()` during a failing group's drain is discarded | 4.F1–F3 |
| B2 | A cancelled receiver loses a message whose send succeeded; a sender whose value was delivered still raises `CancelledError` | 4.F4–F5 |
| B3 | A sibling reading the failing child's `result()` in `finally` turns the group's failure into `CancelledError` | 4.F6 |
| B4 | `Float %` takes the dividend's sign with a negative divisor, and `x % infinity` is not NaN (5.3) | 3.2–3.3, 6.02 |
| B5 | `Float //` floors the rounded quotient, so `(a // b) * b + a % b` is not `a` | 6.03 |
| B6 | `split` and `replace` return NFC text instead of the receiver's bytes (9.1) | 6.04 |
| B7 | `round_to` changes large values it should leave alone | 6.05 |
| B8 | `**` and `Math.power` lose precision for large exponents (about 10,000 ulps) | 6.06 |
| B9 | `Csv.format` loses a row with one empty field; a CSV separator can match inside a grapheme | 6.07–6.08 |
| B10 | Inside a generic body, `x is Int` is false and `type_name` prints `T` (4.4 says runtime type) | 8.C1 |
| B11 | A string inside a collection does not escape `#{` or control characters when displayed | 8.C3 |
| B12 | Constructing a nested type sets up its encloser's type-level fields; a subclass does not set up its base's; what initializes a module file depends on how its type is reached | 3.4, 8.S3–S4 |
| B13 | `TZ` set to a zone name ignores Emerald's built-in zone database; the local zone's name is not normalized | 5.Z1–Z2 |
| B14 | The formatter keeps a byte-order mark and a CRLF comment's `\r`; the language server's formatting disagrees with `emerald format` on both | 3.5–3.6, 2.6–2.7 |
| B15 | **A regression of mine (PR #52):** running another file than `main.em` describes the project's `main.em` as a copied library's demo | 3.13 |
| B16 | `Path` on Windows: `join` uses `/` while the other functions follow the host (predicted; confirm with the Windows run) | 5.P1–P2 |

## C. Diagnostics: fix in two batches, no decision needed

Error messages are part of the product (principle 8), and area 7's corpus is the measure: half of
314 mistakes get a diagnostic that is right on all four questions. These raise it.

| # | Finding | From |
| --- | --- | --- |
| C1 | An unknown word starting a statement (`def`, `elif`, `let`, `function`, `switch`, `unless`, misspelled keywords) is "this result is never used" with an unrelated help; 23 programs | 7.F1, 3.16 |
| C2 | Operators from other languages (`=<`, `<>`, `===`, `mod`, `=+`, `in`), `//` and `/* */` comments, curly quotes, C-style `for`, and other languages' lambda and dictionary shapes are reported as some other problem | 7.F7–F12 |
| C3 | A missing `)` is reported on the next line; a misplaced `super(...)` at the constructor's header | 7.F13–F14 |
| C4 | Other languages' built-ins (`len`, `int`, `str`, `range`, `True`, `null`, `console.log`) get only "not defined", where `.length` already gets "Emerald calls this…" | 7.F16 |
| C5 | Helps that, followed literally, do not fix the program: String and number mixing, optionals, operators, a missing type, keywords as names, and "cannot be used as values" contradicting the guide | 7.F17–F24 |
| C6 | Misleading checker messages: a duplicate function does not name the first, a bare block is explained as a lambda, `(Int) -> Int` as a tuple, historical spellings get no redirect, CSV blames a generic parameter, operator help is number-only, an enum value after a member cascades, `Weekday` help says to edit a built-in, a private field with no default is blamed on its type | 3.14–3.23 |
| C7 | `while true` with no `break` warns at the wrong line with a reason that is not true | 7.F3 |

## D. Decisions for you

Each recommendation was accepted by the user on 2026-10-29.

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | `round_to` and `format` round the shortest decimal display (`2.675.round_to(2)` is `2.68`; Python gives `2.67`). Which is intended? | **Keep the decimal rounding** and say so in 9.3: a beginner reads `2.675` and expects `2.68`. |
| D2 | Runtime error message text: programs can read it (`error.message`) and 49 cases print it, but no section specifies it, so a compiler can only pass by copying the interpreter's strings. | **Make the text part of the contract**, with the conformance suite as its specification, and have the compiler share the interpreter's message code rather than re-create it. |
| D3 | Two cases pin the recursion limit at exactly 1,000 through `(999 times)` in a trace, which 7.2 says is not part of the language. | **Rewrite those two cases** to recurse a fixed depth that raises its own error, so no test depends on the limit. |
| D4 | Features the spec states but that do not exist: `Range` `map`/`take`/`drop`, `Dict`/`Set` `take`/`drop` (8.6), capturing a built-in method (7.4), hover inheriting documentation (3.2), the misleading-indentation warning and close-spelling suggestions (17.2), the unreachable warning after `exit()` (14.1). | **Build** close-spelling suggestions, the warning after `exit()`, and hover inheritance (each small and useful). **Move to "later" in the spec** the `Range`/`Dict`/`Set` additions (`to_list()` covers them), built-in capture (a lambda covers it), and the indentation warning (the formatter makes indentation unambiguous). |
| D5 | New warnings for silent mistakes: discarding a non-changing method's result (`name.trim()` alone, `scores.sort()` alone); `"${name}"` and `"{name}"` in strings; printing a function's `Nothing` result. | **Add all three as warnings**; each is a mistake beginners make and none is ever intended. Infinite loops in general stay undetected (it is undecidable), but C7 fixes the wrong warning. |
| D6 | `map_keys` with colliding keys gives a smaller dictionary; its page says the result is the same size. | **Make a collision an error** that names the two keys: silently dropping entries is the worse surprise. |
| D7 | A task cancelled before it ever ran executes its whole body (15.13 does not say). | **It should not run**: cancel it before it starts, and its `result()` raises `CancelledError`. |
| D8 | Fifteen behaviors the spec is silent about but a program can observe (8.S5–S17): set-algebra order, how often `equals`/`hash`/`compare` are called, indexed-assignment order, `print` rendering after evaluating every argument, channel wake-up order, the struct and class display form, string ordering's normalization, test order and shared state, `FileWriter` visibility before `close`, out-of-memory, deadlock message numbering, unnamed operand orders, and statically known duplicate keys. | **Accept the report's proposed sentences**, which mostly state what the interpreter does now, so the compiler has a written contract and the conformance cases stay valid. I would list any I disagree with in the batch rather than here. |

## E. The spec's own corrections: fix, no decision needed

- 9.2 still says `words`, `letter?` and `digit?` "remain deferred" (my slip in slice 1); so does `docs/library/string.md`.
- 17.1's list of reported warnings names four; about eleven exist.
- The checker's help still says method calls through `?.` "arrive in the next slice"; they work.

## Proposed order of work

1. **A** (crashes and memory), then **B1–B3** (tasks and `exit`) and **B15** (my regression).
2. **B4–B14** (wrong answers), with **D1, D3, D6, D7** as decided.
3. **E** and **D2, D8** (the spec's corrections and contract sentences), so the compiler has its contract.
4. **C** and **D4, D5** (diagnostics and the features decided), in two batches.
5. **B16** once the Windows run confirms it.

One commit per finding, each with the reproduction as a conformance case or test, in PRs of about
ten, each through the full gate and `/code-review` (plan, section 6). Area 2's mutation sweep and
area 1's allocation-failure harness are rerun at the end, as the plan's "done when" asks.
