# Coverage before the review

Measured 2026-10-28 on main at `d580f40` (Zig 0.17.0), with `kcov` on Linux (aarch64, in Docker) over the four test binaries the build runs: unit tests (`emerald-test`), the conformance suite, the language server's tests, and the REPL's. Lines are the executable lines `kcov` reports, so blank lines, comments, and declarations do not count. This is a map of where the suites are thin, not a target (`codebase-review-plan.md`, section 3).

**Overall: 93.3%**, 29,534 of 31,650 executable lines in `src/`.

## By file, most unexecuted lines first

| File | Unexecuted | Executable | Covered |
| --- | --- | --- | --- |
| `src/Lsp.zig` | 598 | 3552 | 83.16% |
| `src/Interpreter.zig` | 487 | 6612 | 92.63% |
| `src/Checker.zig` | 364 | 6721 | 94.58% |
| `src/Parser.zig` | 201 | 2680 | 92.50% |
| `src/emerald.zig` | 86 | 2009 | 95.72% |
| `src/Http.zig` | 56 | 325 | 82.77% |
| `src/conformance.zig` | 44 | 321 | 86.29% |
| `src/Resolver.zig` | 31 | 1445 | 97.85% |
| `src/Scheduler.zig` | 31 | 621 | 95.01% |
| `src/BuiltinParity.zig` | 25 | 369 | 93.22% |
| `src/Regex.zig` | 19 | 733 | 97.41% |
| `src/Heap.zig` | 18 | 932 | 98.07% |
| `src/Json.zig` | 18 | 619 | 97.09% |
| `src/Repl.zig` | 18 | 241 | 92.53% |
| `src/strings.zig` | 15 | 441 | 96.60% |
| `src/Formatter.zig` | 15 | 905 | 98.34% |
| `src/Value.zig` | 15 | 351 | 95.73% |
| `src/Type.zig` | 15 | 404 | 96.29% |
| `src/unicode.zig` | 13 | 437 | 97.03% |
| `src/Csv.zig` | 9 | 173 | 94.80% |

## The largest unexecuted runs

Runs of eight or more consecutive unexecuted lines, 23 in all; the largest:

| Lines | Where | Function |
| --- | --- | --- |
| 61 | `src/Lsp.zig:2947-3041` | `onPrepareRename` |
| 43 | `src/Interpreter.zig:2846-2920` | `reachFile` (test mode's lazy bindings) |
| 30 | `src/emerald.zig:1456-1489` | `sessionExecutionComparison`, a manual benchmark, so expected |
| 25 | `src/Lsp.zig:2291-2328` | `findDeclNameInStatement` |
| 25 | `src/Interpreter.zig:1035-1062` | `run` (an embedding entry point) |
| 24 | `src/Lsp.zig:3956-3987` | `collectLocalCandidatesInStatements` (completion) |
| 22 | `src/Lsp.zig:4116-4144` | `collectLambdaCandidatesInExpression` (completion) |
| 21 | `src/Lsp.zig:2340-2371` | `findDeclNameInExpression` |
| 19 | `src/Checker.zig:4896-4919` | `replaceSelf` |
| 18 | `src/Lsp.zig:2555-2574` | `collectReferencesInUsings` |
| 18 | `src/Lsp.zig:1200-1230` | `onFormatting` |
| 16 | `src/Scheduler.zig:675-693` | a test's thread body, so expected |
| 14 | `src/Lsp.zig:2161-2180` |  |
| 13 | `src/Lsp.zig:2389-2408` |  |
| 13 | `src/Lsp.zig:2196-2215` |  |
| 12 | `src/Lsp.zig:1099-1114` |  |
| 12 | `src/Checker.zig:2575-2589` | `structurallySuppliesTrait` |
| 11 | `src/Lsp.zig:1871-1884` |  |
| 11 | `src/Lsp.zig:1734-1750` |  |
| 9 | `src/Lsp.zig:1847-1858` |  |
| 8 | `src/emerald.zig:1405-1415` |  |
| 8 | `src/Parser.zig:251-259` |  |
| 8 | `src/Lsp.zig:4052-4060` |  |

## What it says for the review

- **The language server is the thinnest area** (83%, 598 unexecuted lines): whole request handlers (`prepareRename`, formatting) and several declaration-finding and completion walks run in no test. Area 2's broken-input campaign should drive the server, and area 3 should add LSP cases.
- **`Http.zig` is 83%**: its error paths need a server that misbehaves, which the HTTP conformance fixture only partly provides.
- **The interpreter and checker are above 92%**, so their review is about wrong answers and untested rules rather than unexecuted code; their largest gaps are named above for areas 1 and 3.
- Two gaps are expected: a manual benchmark (`sessionExecutionComparison`) and a test's thread body.
- `kcov` maps optimized-away or inlined Zig lines imperfectly, so a single unexecuted line is weak evidence; a run of several is strong.
