# Area 2: robustness on broken input

Run on `claude/review-robustness` at `d580f40`, macOS (arm64), Zig 0.17.0, Debug build
(`mise exec -- zig build`) unless a finding says otherwise. Findings were seen on macOS only;
none depends on the platform except finding 4, which depends on stack size.

## What ran

| Run | Mutants | `check` | `format --check` | `format` ×2 + re-`check` | language server |
| --- | --- | --- | --- | --- | --- |
| Sweep 1: seed 20261028, one mutant per operator per file | 5,786 | 5,786 | 5,786 | 5,786 | 5,786 sessions, about 115 requests each (about 665,000 requests) |
| Sweep 2: seed 2, two mutants per operator per file, no server | 11,570 | 11,570 | 11,570 | 11,570 | none |
| Multi-file projects: every file of the 50 conformance projects mutated in place, project copied whole | 662 | 662 | none | 662 (once) | 662 sessions (for `main.em`) |
| Byte-level variants: 12 examples × 13 (CRLF, CR, BOM, tabs, NUL, U+2028, NBSP, ZWJ, no final newline, and others) | 156 | 156 | 156 | 156 | 156 sessions |
| Deep nesting: 6 shapes × 4 depths (100 to 100,000), and 5 shapes at depth 9,000 | 29 | 29 | none | 29 | 15 sessions, 10 methods each |
| Protocol probes: malformed JSON-RPC, framing, parameters, URIs, lifecycle | 52 sessions | | | | 52 |

In all, about 18,200 mutated programs through `check` and `format`, and about 6,700 server
sessions. Sweeps 1 and 2 took every `.em` file under `conformance/` and `examples/` (983 files) and
applied six operators: delete a token, duplicate a token, swap two adjacent tokens, truncate at a
random byte, insert a keyword or bracket, and replace an identifier with another from the same file.
Each server session opened the mutant, asked hover, completion, definition, references,
prepareRename, rename, signatureHelp and codeAction at seven positions (start, end, four random
token positions, one past the end), plus formatting and documentSymbol; then changed the document
to the original and asked again; then changed it back, closed it, and shut down. Every reply was
checked for JSON-RPC shape, a matching id, ranges inside the document, and, for formatting,
agreement with `emerald format`.

Rerun with:

```
mise exec -- zig build
python3 docs/review/repro/robustness/mutate.py zig-out/bin/emerald --out /tmp/sweep1
python3 docs/review/repro/robustness/mutate.py zig-out/bin/emerald --seed 2 --per-op 2 --no-lsp --out /tmp/sweep2
```

Reproductions are in `docs/review/repro/robustness/`. A server reproduction is an `.em` file and a
`.json` list of requests, replayed with
`python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/NN-name.json`.

## Findings, most severe first

### 1. `check` crashes when two declarations share a name

A declaration that reuses a name in the same scope is one of a beginner's commonest mistakes, and
the checker panics on it when the duplicate's body calls a member. There are three crash sites,
all of the form `self.facts.calls.getPtr(caller).?`: the caller's entry is missing because a second
declaration took its key. ReleaseSafe crashes the same way. The server crashes on didOpen too,
because it runs the same analysis, so the editor loses the server as soon as such a file opens.

| Reproduction | Crash site | Found by |
| --- | --- | --- |
| `03-enum-value-property-clash.em`: enum value `b` and property `const b: E { return E.a }` | `src/Resolver.zig:2471:40`, `noteTypeMember` | sweep 1, renaming `snowy` to `advice` in `examples/enums.em` |
| `08-duplicate-name-operator-call.em`: `func f()`, then `struct f` whose method does `self.v > 1` | `src/Resolver.zig:1022:63`, `noteMemberCall` | sweep 2, `generics-parameter-order.em` |
| `09-duplicate-type-method-call.em`: two `struct S`, the second calling `self.d()` | `src/Resolver.zig:1022:63`, `noteMemberCall` | sweep 2, `examples/traits.em` (`struct Book` renamed to `Song`, which then reaches `src/Resolver.zig:3069:96` in `walkExpression`) |

Copy a reproduction alone into an empty directory as `main.em`, then:

```
emerald check main.em
```

> `thread … panic: attempt to use null value` at `src/Resolver.zig:2471:40` in `noteTypeMember`
> (for `08` and `09`: at `src/Resolver.zig:1022:63` in `noteMemberCall`)

Without the member call the same programs report "`f` is already declared" or "`b` is already a
value of `E`". What should happen: that diagnostic, with no crash.

### 2. Renaming a declaration that shares a built-in's name crashes the server

`02-rename-builtin-shadow.em` is two lines, `struct String {` and `}`, and `emerald check` reports
"No problems found." Renaming `String` at 0:7 kills the server. The same happens for `struct Int`
and for a user `func print()`. Sweep 1 hit it in 7 mutants, all through `replace-ident`. ReleaseSafe crashes
the same way.

```
python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/02-rename-builtin-shadow.json
```

> `thread … panic: index out of bounds: index 1, len 1` at `src/Lsp.zig:3008:50` in `onRename`
> (`loaded.project.files[site.file]`)

The site collection walks `analysis.parsed`, which includes the prelude, so a site in the prelude
indexes past `project.files`. Find References on the same position answers correctly. What should
happen: rename returns the edits in the user's files (or a clean error), and the server keeps
running.

### 3. A position with `line` 4294967295 crashes the server

`01-position-line-overflow.json` sends a hover at `{"line": 4294967295, "character": 0}`. The same
crash happens for completion, definition, references, rename, prepareRename and signatureHelp;
codeAction is safe because `exactRange` checks first. ReleaseSafe crashes too.

```
python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/01-position-line-overflow.json
```

> `thread … panic: integer overflow` at `src/Lsp.zig:183:37` in `offsetFromPosition`
> (`@min(position.line + 1, last_line)`)

`positionField` accepts any `u32`, and `+ 1` overflows. In ReleaseFast the sum wraps to 0, and
`line_starts[line - 1]` then reads out of bounds. What should happen: clamp to the last line, as
smaller out-of-range lines are. A line of 2^53 is rejected as invalid instead, and finding 5 shows that rejection goes unanswered.

### 4. Deep expressions the checker accepts overflow the server's stack (Debug)

The parser accepts expression depth up to `max_expression_depth = 10_000`. `check` and `run`
handle 9,999 nested unaries and 9,000-term `+`, `and`, or `not` chains. On those programs the
server's recursive walkers overflow the stack:

- References, rename and prepareRename on a use of the variable: `collectReferencesInExpression`
  (`src/Lsp.zig:2804`)
- Hover, definition, references and prepareRename inside the expression: `findAssignmentInExpression`
  (`src/Lsp.zig:1823`), from about depth 4,000

`04-deep-expression-lsp-stack.em` is `var x = ` followed by 9,000 `-`, then `1`, then `print(x)`;
its `.json` asks for references to `x` at 1:6.

> `Segmentation fault at address 0x16c977ea0`, then `in collectReferencesInExpression`

The ReleaseSafe build survives these depths on macOS's 8 MiB main stack. Debug is what the tests
run, and a smaller stack (Windows's default is 1 MiB) is not covered. What should happen: the
server's walkers stay within the depth the parser guarantees, by an explicit stack, or a depth check
that matches the parser's budget, or a server thread with a known stack size.

### 5. Malformed requests are never answered

When a request's parameters are malformed, the server answers nothing: it drops the request and
goes on. Examples are a negative or non-integer position, missing or `null` `params`, a `newName`
that is not a string, and rename with no `newName`. This is deliberate (the comment in
`runMessages` says "whatever request it was simply goes unanswered"). JSON-RPC 2.0, though, says a
request must get a response. An editor waiting on that id waits forever, and the request stays in
its pending set.

```
python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/05-malformed-request-unanswered.json
```

Three requests (ids 1, 2 and 3) go out and none is answered; only `initialize` and `shutdown`
replies come back. What should happen: `{"error": {"code": -32602, "message": …}}` for each id,
which `respondError` with `invalid_params_code` already does for other cases.

### 6. LSP formatting leaves a trailing lone carriage return that `emerald format` removes

`06-format-trailing-cr.em` is `var x = 1` followed by a lone `\r`. `emerald format` writes
`var x = 1\n`. The server's formatting edit is the range `0:0`–`0:9` with `"var x = 1\n"`, which
stops before the `\r`, so the editor ends with `var x = 1\n\r`.

```
python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/06-format-trailing-cr.json
```

> `"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":9}},"newText":"var x = 1\n"`

A lone CR is not a line break to the lexer, and `Source.lineText` trims a trailing `\r` from line
text, so the whole-document edit stops one byte short. What should happen: the edit's end covers
the whole document (line 1, character 0, or the document's real end), so the result matches
`emerald format`. This is low severity, since files with lone CRs are rare.

### 7. LSP formatting drops a byte-order mark that `emerald format` keeps

`07-format-bom-dropped.em` is a canonical one-liner with a UTF-8 BOM. `emerald format` leaves the
file alone, BOM included. The server answers with a whole-document edit from `0:0`, which removes
the BOM. Most editors strip the BOM from the buffer before the server sees it, so this is low
severity, but the two formatters disagree, and the server sends an edit for an already canonical
file.

```
python3 docs/review/repro/robustness/send.py zig-out/bin/emerald docs/review/repro/robustness/07-format-bom-dropped.json
```

> `"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}},"newText":"var x = 1\n"`

What should happen: the same result as `emerald format` (keep the BOM, or drop it in both), and no
edit for a file that is already formatted.

## Came out clean

- **The formatter, on broken input.** Across the two sweeps (17,356 formatted mutants), no
  crash, no hang, no leak, and no non-idempotent output. `format` never turned a program that
  checks into one that does not, and `format --check` never crashed. CRLF, CR, BOM, tabs, U+2028,
  NBSP and a missing final newline were all formatted idempotently by `emerald format`. The
  server disagrees only in findings 6 and 7.
- **`check` on mutants.** Apart from the three programs in finding 1 (one crash in sweep 1, two in sweep 2), no panic,
  signal, leak, hang, or exit 70 in about 18,200 runs.
- **Nesting limits.** Brackets, blocks, parentheses and string interpolation from 1,000 to 100,000
  deep get a clean diagnostic from `check` and `format`. The 256-delimiter and 10,000-depth budgets
  work as stated.
- **The language server on mutants.** Apart from findings 1 and 2 (7 rename crashes and 1 crash on open in
  sweep 1), no crash, hang, leak on exit,
  malformed reply, internal error, or out-of-document range across about 6,600 mutant sessions.
  That includes single files and whole multi-file projects, and the didChange round-trip. LSP
  formatting agreed with `emerald format` on every token-level mutant both could format.
- **Protocol robustness.** Invalid JSON, a JSON scalar or array body, an empty body, LF-only
  headers, a 100,000-deep JSON array, string, null, object and float ids, unknown methods,
  `$/cancelRequest`, requests for unopened or closed documents, double didOpen and didClose,
  didChange for an unknown URI or with a range, NUL and lone surrogates in the text, `untitled:`
  and percent-encoded URIs, and positions inside a surrogate pair: all handled without a crash.
- **Not counted as findings.** A missing, negative, non-numeric or huge `Content-Length` ends the
  server with exit 70 and "the client's message was not framed correctly". The stream cannot be
  resynchronised after a framing error, so this is a clean failure.

## Harness notes

- Three false positives in the first sweep came from the harness, not the server, and are fixed in
  `mutate.py`. Range checks for the last request were made against the wrong text; files were read
  with universal newlines, which hid CRLF; and rename edits for other project files were checked
  against the open file. Sweep 1's 16 "hover range outside the document" reports, from 14 mutants, were all the
  first of these. Rerunning those 14 with the fixed script came out clean.
- The project sweep and byte-variant runs used `mutate.py`'s functions from small driver scripts
  that are not committed; both are a loop over `mutate.examine` / `mutate.lsp_session`.
