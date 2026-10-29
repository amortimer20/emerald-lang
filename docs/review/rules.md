# Review area 3: rules without cases

Date: 2026-10-28 to 2026-10-29. Branch `claude/review-rules`. Worklist: the **none** rows of
`docs/review/rule-coverage.md`. Method: for each row, write the smallest case that exercises
just that rule, with its spec section in the first-line comment, and run it on main's
interpreter (Zig 0.17.0, `zig build -j1`). A rule that holds keeps its case. A rule that fails
gets a reproduction under `docs/review/repro/rules/` and no golden file. Sections were taken in
order, and the work stopped at the time box after 15.13 (with a few rows in 16 and 18
checked by hand).

## Counts

| | |
| --- | --- |
| Rows worked | 129 of 137 (all of 3.1 through 15.13, plus 16.3, three rows of 18.1, and 18.4) |
| Conformance cases added | 84 (39 `diagnostics/` including 2 projects, 35 `run/` including 1 project, 9 `runtime-errors/`, 1 `lsp/`), all passing `zig build test -j1` |
| Rows now covered by a kept case | 96 |
| Findings | 23 (25 reproductions). 20 worklist rows fail outright; the rest are bugs found along the way |
| Untestable as a conformance case | 13 rows, each checked by hand (see below) |
| Rows not reached | 8 |

## Findings, ranked

Section numbers refer to `docs/rewrite-context.md`. Reproductions are in `docs/review/repro/rules/`.
Everything was seen on macOS (Darwin 27, arm64) only.

### Crashes and wrong answers

1. **An assertion's interpolated message prints garbage bytes** (`22-assert-interpolated-message-garbage.em`).
   `assert n == 4, "expected #{n}"` reports `UUUUUUUUUU Left was 3; right was 4.`: one `U` per
   byte of the message, which looks like freed or uninitialized memory. A plain literal message,
   or an interpolated one stored in a variable first, prints correctly. 16.2 says an
   assertion reports its message. This is probably a lifetime bug, so it goes to area 1 too.
2. **Float `%` ignores a negative divisor's sign** (`06-float-remainder-negative-divisor.em`).
   `7.5 % -2` gives `1.5`, `7.0 % -2.0` gives `1.0`, and `7 % -2.0` gives `1.0`, and
   `(7.5 // -2) * -2 + (7.5 % -2)` gives `9.5`, not `7.5`. `Int` is right (`7 % -2` is `-1`).
   5.3 says: "`%` uses the matching floor-division law `a == (a // b) * b + (a % b)`; for
   finite operands a nonzero remainder has the divisor's sign." The cause is
   `src/Interpreter.zig:3913`, `@mod` on floats.
3. **An infinite divisor does not give NaN** (`07-float-remainder-infinite-divisor.em`).
   `5 % infinity` and `5 % -infinity` give `5.0`, while `-5 % infinity` gives NaN. 5.3 says "A
   NaN or infinite remainder operand produces NaN." The comment at `Interpreter.zig:3912` says
   `@mod` already does this. It does not.
4. **Constructing a nested type sets up the enclosing type instead of itself**
   (`19-nested-construction-sets-up-encloser.em`). `Theme.Pair(left: 1)` runs `Theme`'s
   type-level field setup and not `Pair`'s. The output is `start / setting up Theme /
   constructed`. 14.3 says reaching a nested type's member "sets up that nested type's
   type-level fields (14.1), not its enclosing type's", and 10.4 says setup happens "the first
   time the type is constructed". (Reaching `Theme.Pair.made` correctly sets up only `Pair`.)
5. **The formatter keeps a byte-order mark** (`01-format-keeps-bom.em`). `emerald format` on a
   file that starts with a BOM reports nothing and leaves the BOM in place. 3.1 says "The
   formatter writes UTF-8 without a byte-order mark".
6. **The formatter keeps the CR of a CRLF comment line** (`02-format-comment-keeps-cr.em`,
   kept byte-exact by a local `.gitattributes`). `# c\r\nprint(1)  # trailing\r\nprint(2)\r\n`
   formats to `# c\r\nprint(1) # trailing\r\nprint(2)\n`. Code lines become LF, but comment
   text keeps its `\r`, so the output mixes line endings. 3.1 says the formatter "uses one
   consistent line-ending style." A CRLF-only file without comments formats to clean LF. A
   golden file can't catch this, because git normalizes the input to LF and the runner strips
   `\r`.
7. **Output still buffered at exit, written to a closed pipe, prints a Zig stack trace**
   (`25-closed-pipe-final-flush.em`, found along the way). `emerald run … | true` prints
   `error: WriteFailed` and Zig frames from `src/main.zig:482` (`out.interface.flush()`) and
   exits 1. The same closed pipe hit during the run prints `emerald: could not write the
   program's output` and exits 70. 13.2 says "Zig frames and implementation details must not
   appear", and 18.1 reserves 70 for internal failures.

### Stated behavior that is missing

8. **Hover does not inherit documentation** (`03-override-hover-no-inherited-doc.em`,
   `04-requirement-hover-no-doc-sources.em`). Hover on an undocumented `@override`, or on an
   implementation of two documented trait requirements, shows only the signature. 3.2 says
   tools "inherit the text from the overridden declaration or satisfied trait requirement and
   label its source", and "If several requirements contribute different text, the tool
   presents each source". Hover is Emerald's only documentation tool (18.5).
9. **Built-in methods cannot be captured** (`10-builtin-method-not-capturable.em`).
   `const typed: func(func(Int): String): List[String] = numbers.map` is rejected with
   "List[Int] has no property `map`", and `numbers.contains?` with "Methods cannot be used as
   values yet". 7.4 says "Every method remains capturable" and gives exactly this annotated
   form as valid. `docs/journal.md:965` records this as still to do, but the spec does not
   mark it deferred. The `map` message is wrong as well as unhelpful: `map` exists.
10. **`Range` has no `map`, `take`, or `drop`** (`12-range-has-no-map-take-drop.em`). Each is
    "Range has no method". 8.6 says "`range.map` returns a completed list" and that `take` and
    `drop` "on a range return a completed list", and 9.4 lists "eager rich transformations" for
    Range. `docs/library/range.md` documents none of them.
11. **`Dict` and `Set` have no `take` or `drop`** (`13-dict-set-have-no-take-drop.em`). 8.6
    says they "do the same [keep the receiver's kind], using insertion order for dictionaries
    and sets". The spec is partly self-contradictory here: the same section says "The first
    value-transform slice applies `take`, `drop`, `reverse`, and `unique` to lists." Either
    the spec should mark these as later, or the methods are owed.
12. **No unreachable-code warning after `exit()`** (`18-no-warning-after-exit.em`). `exit(0)`
    followed by `print("two")`, at the top level or in a function, gets "No problems found."
    14.1 says "Unreachable executable statements after unconditional `return`, `raise`, loop
    exit, or `exit()` produce a warning". The other three are warned about.

### Wrong or misleading diagnostics

13. **Choosing another entry blames `main.em` as a library demo** (`20-select-entry/`).
    `emerald run project/other.em`, in a project whose `main.em` has any top-level statement,
    fails: "Only the project's own `…/other.em` runs its top level, so `…/main.em` never does.
    A library keeps its demo in the project around it". That help was written for a nested
    `main.em` (`src/Resolver.zig:1217`), not for the project's own entry. As a consequence,
    14.1's "`emerald run path/to/file.em` may select another entry explicitly" works only when
    `main.em` holds declarations alone. Whether that is intended is a question for the spec.
14. **A duplicate function in one file does not name the first**
    (`11-duplicate-function-does-not-name-first.em`). It reports "`area` is already declared"
    with no location, while the cross-file case names the other file. 7.3 says the error names
    the first declaration.
15. **A bare block is explained as a lambda** (`05-bare-block-lambda-message.em`). It reports
    "expected a lambda parameter, found var". 3.4 says such a block is not a scoping
    statement, and to use a named function or control flow.
16. **`unless` gets "this result is never used"** (`08-unless-unused-result.em`). 6.2 explains
    there is no `unless`, and that `if not` is the spelling. A targeted message like the one
    semicolons get would help.
17. **`(Int) -> Int` is explained as a one-element tuple**
    (`09-arrow-function-type-tuple-message.em`). The help, "Drop the parentheses", produces
    `Int -> Int`, which is still wrong. 7.1's spelling is `func(Int): Int`.
18. **Historical spellings get no redirect** (`14-historical-spellings-no-redirect.em`).
    `pad_left`, `pad_right`, `intersect`, `read_line`, and `Kernel` get generic "no method" or
    "not defined" messages, while `slice` and `has_key?` are redirected. 9.4 names all of them
    together. The checker's rename tables (`src/Checker.zig` around line 10225) lack these
    five.
19. **CSV blames a generic field's parameter** (`15-csv-generic-field-message.em`).
    `Csv.encode` of a `List[Pair[Int, String]]` says "field `first` … cannot be written as CSV
    because it is First". The help then lists whole numbers, which is what `first` holds. 11.3
    says Csv does not take generic types, so the message should say that.
20. **Operator errors on user types give number-only help**
    (`16-optional-left-operand-message.em`, `17-unary-minus-struct-bool-help.em`). `price * 3`
    with `price: Money?` says "multiplication needs numbers … Arithmetic works on Int and
    Float", although `Money` registers `*`. The real problem is the optional left operand
    (11.5). `-Point(1)` gets the help "Use `not` to invert a Bool."
21. **An enum value after a member cascades into a false error**
    (`21-enum-member-order-cascade.em`). The order errors are right, but they are followed by
    "an enum needs at least one value", which is false: the enum has two.
22. **`Weekday` comparison tells the user to edit a built-in**
    (`23-weekday-ordered-help-builtin.em`). The help is "Add `with Ordered` to `Weekday`, and
    give it `@override func compare…`". 15.8 says `Weekday` deliberately does not adopt
    `Ordered`, and a program cannot change it.
23. **A private field with no default is blamed on its type**
    (`24-json-private-no-default-message.em`, `24b-csv-private-no-default-message.em`).
    `Json.decode` and `Csv.decode` say "field `_token` … cannot be read … because it is String",
    and the help then lists strings as readable. 15.9 and 15.11 say the error is the missing
    default.

The rule holds in each of 15 to 23, but the message would mislead the beginner who hits it, so
none has a golden file.

## Untestable as conformance cases (checked by hand, all hold)

- 3.2 "documentation warnings apply to program files, not the prelude": the prelude is fixed,
  and every clean `check` already shows it gives no warnings, so there is no dedicated case.
- 14.1, three rows: independent exercises with a shared `helper`, the project root found from
  another working directory, and a subdirectory file run alone, which names the entry. Each
  needs the CLI and its working directory. `build.zig` is off-limits for this area. (Choosing
  another entry is finding 13.)
- 15.1, the runtime-error half of "keep the field-based form": no runtime error message
  displays a user value, so nothing can show it. The assertion half is
  `runtime-errors/assertion-field-based-form`.
- 15.2 `print_error` strips styling when stdout is styled and stderr is not; 15.6 `clear` is
  unaffected by `--color=never` and `NO_COLOR` but suppressed by `TERM=dumb`. Both need a
  pseudo-terminal (`script -q`). Both hold.
- 15.10 text and JSON bodies set `text/plain; charset=utf-8` and `application/json` unless
  `headers:` gives one, and bytes set none. This needs a server that echoes headers, and the
  test server's `/echo` does not, so it was checked against a local Python server. The
  scheme rule did get a case (`run/http-scheme-only`).
- 16.3, two rows: the test output names the file, test, expression, and trace; tests run in
  declaration order; and `3 tests, 1 failed.` with status 3. All are CLI output.
- 18.1, three rows: `emerald help lsp` shows `[--stdio]`, `lsp` is absent from the banner, and
  `emerald new` exits 64.
- 18.4: the REPL echoes `nothing` for an optional holding `nothing`. A `repl/` case could hold
  this, but it was not written for lack of time.

Also, 9.4's wording is only that the spellings "remain rejected". The worklist's "with
Emerald's name" goes further than the spec, so finding 18 is a diagnostic-quality finding, not
a broken rule.

## Cases added

`diagnostics/`: arrow-lambda, assign-through-optional-chain, backslash-continuation,
bang-forms-on-const, bool-case-coverage, builtin-type-named-bare, case-arm-scope,
conflicting-requirement-types, csv-enum-data, enum-case-empty-else, hashable-class-key,
historical-spellings, implicit-nothing-return, is-test-no-false-warning,
json-encode-unsupported, mutable-property-not-narrowed, nested-function-self,
nested-self-is-nested-type, operator-annotation-private, operator-annotation-private-type-level,
operator-method-shape, operator-override-repeats, operators-not-overloadable,
private-cannot-satisfy-requirement, private-keyword, question-name-class-override,
range-line-does-not-continue, set-comparison-operators, setter-value-read-only,
shared-trait-not-inferred, top-level-return-non-entry/ (project),
trait-changing-default-on-struct, trait-conflict-reported-once, tuple-collection-operations,
type-level-field-not-narrowed, unreachable-after-branches, using-file-local/ (project),
variadic-parameter, while-true-literal-only.

`run/`: class-getter-changes-object, class-in-struct-identity,
class-method-outranks-trait-default, collection-type-name-static, colliding-calculated-keys,
compatible-duplicate-requirements, compound-assignment-order, csv-private-fields,
dictionary-key-copied, dictionary-stored-nothing, equal-endpoints, file-paths-and-creation,
float-remainder (positive divisors and NaN only; see findings 2 and 3),
generics-type-name-bytes-traits, http-scheme-only, input-keeps-whitespace,
json-encode-tree-private, local-zone-utc-embedded, loop-snapshot-dict-set,
multiline-escaped-newline, nested-function-after-return, nested-function-defaults,
nested-type-self-and-setup, numeric-edge-results, optional-operation-no-second-layer,
private-field-equality, property-not-cached, regex-empty-rounds, sibling-class-inline-if,
space-minus-subtraction, string-edge-results, string-keeps-bytes, task-done-failure-cancel,
using-lazy-and-file-local/ (project), wrong-side-block-forms.

`runtime-errors/`: assertion-field-based-form, compound-assignment-overflow,
input-invalid-utf8, int-domain-to-list, partition-empty-separator, replace-empty-old,
reraise-keeps-location, slice-start-after-end, string-slice-start-after-end.

`lsp/`: trait-private-helper-completion.

Note: `run/local-zone-utc-embedded` expects `UTC true`, which is right for the embedded runner
(15.8). Run through the CLI, it prints the machine's zone. Its golden file was generated with
`TZ=`.

## Rows not reached

- 16.1 a native built-in listed deprecated with the same message
- 16.2 assertions stay active in optimized builds
- 17.2 the indentation warning (already known, so skipped)
- 18.1 status `70` for an internal failure
- 18.3 `(-9223372036854775808)` keeps its parentheses before `.`, `(`, and `[`
- 18.3 `format <path>` formats the whole project
- 18.3 `--check`'s listed output
- 18.3 a silent run when canonical, else a count
