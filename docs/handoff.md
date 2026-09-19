# Current handoff

Updated: 2026-09-19. This file is the live status a session starts from — replace stale
paragraphs here rather than appending to them, per `AGENTS.md`. Completed-slice narrative,
past validation runs, and non-obvious implementation lessons live in
[`docs/journal.md`](journal.md) instead, an append-only historical record; move a section
here into it once it's no longer current rather than letting it accumulate.

## Current status

The Zig rewrite implements essentially all of the rewrite context's language surface:
functions, loops, lists, strings, callables, optionals, dictionaries and sets, tuples,
structs, classes, inheritance, traits, `Self` and operator overloading, enums and `case`,
errors and `try`/`catch`/`finally`, `assert` and `@test`, multi-file projects with
namespaces and `using`, and range values as first-class values. The formatter
(`emerald format`), REPL (`emerald repl`), and the LSP's first slice (`emerald lsp`:
diagnostics, document symbols, format on save) are also complete. `zig build test` passes in
both Debug and ReleaseSafe with the pinned Zig 0.16.0. See `docs/journal.md`'s "Slice 14 and
the object model" and "Slice 15 completion" sections for how each of these was built and
what was learned along the way.

Release hardening has also substantially landed (`2d5aa0b`, `ed41d24`, `00cfae3`), under that
name rather than as "Slice 16": `.github/workflows/ci.yml` runs `zig build test` in Debug and
ReleaseSafe across Ubuntu/macOS/Windows on every push and PR, plus a bounded 1,000-case
frontend fuzz job; a nightly `fuzz.yml` runs four fixed 10,000-case campaigns
(`tools/fuzz.zig`: lexer → parser → checker → format-twice-for-idempotence over generated
UTF-8 text, including non-ASCII atoms; its first extended run already found and fixed a real
formatter recovery bug). `testing.checkAllAllocationFailures` covers `Lexer`, `Parser`,
`Formatter`, and `Project` exhaustively, plus `checkProject` and `runProject` against a
struct/list/loop/interpolation program broad enough to reach past bare-statement paths
(`src/emerald.zig`). Both `docs/journal.md` (its "Slice 15 completion" section) and this
file, before this pass, still described all of this as "Slice 16, queued" — stale by three
commits' worth of work each of which updated a different paragraph of the old, since-split
handoff without reconciling that older claim. This pass closed the specific gap that
survived that staleness (allocator-failure testing and fuzzing never reaching the checker or
interpreter, detailed in the previous "Next step") by adding the `runProject` allocator-
failure test above and a checker stage to `tools/fuzz.zig`. The `runProject` test initially
failed for a reason that turned out not to be a bug: `RunError` legitimately includes both
`error.OutOfMemory` and `std.Io.Writer.Error`'s `error.WriteFailed` (`self.out` in
`Interpreter.zig` may be real stdout, where a write can fail for reasons that have nothing to
do with memory, so the interpreter is right not to collapse the two into one). The test's own
output stream, though, is an in-memory `std.Io.Writer.Allocating`, where `WriteFailed` can
only mean its backing (failing, by design) allocator failed — so the test's `Work.run`
converts `WriteFailed` to `OutOfMemory` itself before checking the result, matching what
`checkAllAllocationFailures` expects; no production code needed to change.

**Documentation is complete and is the reference to trust for language and library
behavior**, not this file: every guide `docs/language/README.md` lists is "Drafted" (Core
language, Types and optionals, Collections and ranges, Objects and traits, Errors/tests/
projects), and every family in `docs/library/inventory.md` has its own page (Prelude, `Int`,
`Float`, `Math`, `String`, `List`, `Dict`, `Set`, Tuples, `Range`, `Random`, Errors and
tests). Every claim in every page was cross-checked against source and the built binary
rather than trusted from the rewrite context's prose alone, which is what caught the several
real gaps below. `tools/check-doc-examples.sh` (run after `zig build`) confirms every `.em`
file or project a documentation page links to still exists, and that every linked
`examples/`-file or `examples/`-project actually runs to completion.

That documentation pass found and fixed several real issues, most recently first:

- A statically known duplicate dictionary literal key (`["Ava": 1, "Ava": 2]`) was settled
  design (8.4) but unenforced; `Checker.zig::checkDuplicateKeys` now rejects it, reusing
  `case`/`when`'s existing `knownAlternative` helper.
- Calling a struct's changing method through `?.` used to type-check fine and only raise at
  runtime once the chain ran with a present receiver; it's now rejected at check time,
  matching the already-static rejection of assignment through `?.`.
- A diagnostic ("this list mixes `nothing` with {type}") suggested fixing itself with the
  retired `[String?]` bracket-type spelling, which the parser now rejects outright; it now
  suggests `List[String?]`.
- `List.pairs()` crashed the interpreter on an empty or single-element list
  (`Interpreter.zig:4706`, an integer underflow); fixed and given a regression case.
- `reduce_right` was documented as deferred in both the rewrite context and this handoff,
  but is actually implemented (`0a1b691`) — now documented on the `List` page, and
  `docs/rewrite-context.md`'s own line (1465ish) is corrected in this pass too.
- `docs/rewrite-context.md`'s optional-chaining paragraph (4.4) said only "an assignment or
  changing method call through `?.` is rejected," without saying when or for which receiver
  kind; corrected to match the fix above (check time, struct-only).
- String/List range-slicing (`text[1..<4]`, `list[1..<3]`) and its omitted-endpoint forms
  are described in detail in 5.4 but do not parse or type-check at all (confirmed during
  the full audit below); 5.4 now carries the same "not yet implemented" framing as the
  library's other unbuilt roadmap facilities.

## Next step

Nothing is queued. What remains of the old "Slice 16" backlog, in no particular order:
Unicode conformance is narrower than "full" suggests — only two conformance cases
(`unicode-text.em`, `unicode-names.em`) exist, and the rewrite context (9.2) says
`letter?`/`digit?`/`words`/`title_case`/case-insensitive comparison need "a dedicated locale
and boundary design pass" first, which hasn't happened; `tools/fuzz.zig`'s generator has no
loop keywords and doesn't execute anything, so the interpreter itself is still unfuzzed
(deliberately, for now — see the file's own header comment for the hang-risk reasoning).
Other candidates: the LSP's second slice (hover, go to definition, find references, safe
rename, completion — see the journal for what each needs); or whatever the user directs.
`Section` numbers below refer to `docs/rewrite-context.md`.

## Documentation and rewrite-context hygiene

`docs/handoff.md` and `docs/journal.md` were split apart in an earlier pass (previously one
file, ~2,500 lines, that had accumulated into a session diary rather than the rolling status
`AGENTS.md` asks for) — see the journal's own intro for the convention going forward.

`docs/rewrite-context.md` has since had a full accuracy audit: every claim in sections 1
through 25 was checked against `src/*.zig`, `src/prelude.em`, the conformance suite, and the
built binary (four parallel passes, one per section range, each writing scratch `.em` files
and running `zig-out/bin/emerald` directly rather than trusting the prose). Section 21
("Deferred features") came back fully accurate — every item grepped and re-tested is still
genuinely unimplemented. Elsewhere, the audit found and fixed:

- Three collection methods (`reverse_each`, `flat_map`, `filter_map`) were documented as
  List-only with Dictionary/Set support "deferred," but `Checker.zig`'s `typeOfMapMethod`
  already implements all three for Dictionary and Set too (verified at runtime); corrected.
- `letter?`/`digit?` were listed as accepted String vocabulary in one paragraph (9.2) and
  called deferred two paragraphs later — a direct self-contradiction. Neither is
  implemented; removed from the accepted-vocabulary list, leaving the deferred note as the
  single source of truth.
- The 10.4 type-level-member example declared `func Vector2.origin()` and `var
  Player.count = 0` at top level, outside any type's braces — which the parser rejects
  outright, contradicting the prose two paragraphs later ("declared inside the braces of
  its own type"). Fixed the example to declare both inside their type.
- Section 12 said a nonexhaustive enum `case` statement "produces a warning," while section
  6.3 already correctly said this waits for diagnostic severities and isn't built. Section
  12 now matches 6.3: silently accepted today, no diagnostic at all.
- A `Textual` trait (15.1), the `File`/`Directory`/`Path` API (15.3, plus the 13.3 resource
  example that used it), and the numeric `.format()`/`.to_string(base:)` API (15.5) were
  all presented as settled/current with no caveat, but none of the three exist anywhere in
  `src/`. Each now carries the same explicit "roadmap, not yet implemented" framing that
  15.4 (Regex) already used.
- The CLI command list (18.1) included `emerald new`, `emerald explain`, and `emerald help`,
  none of which exist in `src/main.zig`'s `Command` enum (only `check run test format repl
  lsp` do; `lsp` itself was missing from the doc's list). The `--diagnostic-format=json` flag
  described there is likewise unimplemented. All now marked as later-tooling design, not
  current behavior.
- The LSP feature list (18.5) claimed hover, go-to-definition, find-references, rename, and
  completion as part of "the first useful feature set," but `src/Lsp.zig`'s own header
  comment says the first slice deliberately covers only diagnostics, document symbols, and
  format-on-save, and explains why the rest need infrastructure this slice doesn't build.
  Corrected to match.
- Section 20's implementation-sequence item 10 said the GC slice ships "the explicit root
  API of 19.5," but 19.5 and section 22's own decision table both say roots are derived from
  reference counts specifically *instead of* a registration API — the opposite claim.
  Corrected.
- Section 23's process checklist had "identify whether the old prototype agrees or
  conflicts" as a mandatory step, but no prototype artifacts exist anywhere in this
  repository to consult; repointed at section 22's existing departure table instead.
- 5.4's String/List range-slicing syntax (`text[1..<4]`, `items[2..<]`) was presented as
  settled; none of it works — indexing requires an `Int` and rejects a `Range` outright,
  and the omitted-endpoint forms don't even parse. Given the roadmap framing now used
  consistently elsewhere in this same pass (15.1, 15.3, 15.5), it gets the same treatment
  here rather than being left as a standing exception.

## Completed foundation

- The Zig rewrite is the sole maintained implementation; historical prototype material is
  not part of the repository.
- [rewrite-context.md](rewrite-context.md) is the canonical language and architecture
  baseline. The implementation host is Zig.
- Zig `0.16.0` is pinned through [mise.toml](../mise.toml) and
  [toolchain/zig-version.txt](../toolchain/zig-version.txt), verified by
  [tools/check-toolchain.sh](../tools/check-toolchain.sh).
- Shared agent instructions are committed in `AGENTS.md` and `CLAUDE.md` (`f3c38cb`).

## Implemented so far

- `build.zig` provides `zig build`, `zig build test`, and `zig build run`.
- `src/Project.zig` finds and loads the files a program is made of, which is section
  14.1's rule and nothing more: the file alone, unless its own directory holds `main.em`,
  in which case every `.em` file under that directory comes with it. It derives each
  directory's namespace and reports one that cannot be a name.
- `src/Source.zig` is the immutable source-file record: UTF-8 with byte-order mark removal,
  LF and CRLF line handling, byte-offset spans, and one-based line and scalar-column
  mapping. It also locates the first invalid UTF-8 sequence and its span.
- `src/Diagnostic.zig` renders the canonical four-part shape from section 17.1, with the
  underline measured in scalars so it aligns past multi-byte characters. A runtime error
  also carries a stack trace, innermost call first, with runs of identical frames
  summarized.
- `src/Token.zig` holds the token kinds, the keyword table, and `canEndExpression`, which
  is the continuation-token list section 3.1 refers to. The switch is exhaustive, so a new
  kind cannot be added without classifying it.
- `src/Lexer.zig` produces tokens with spans: names, keywords, numbers, the three string
  forms, comments, operators, statement-terminating newlines, and EOF.
- `src/Ast.zig` is the syntax tree, free of runtime values so a future backend consumes the
  same tree the interpreter does.
- `src/Parser.zig` parses statements and expressions with section 5.3's precedence, and
  bounds nesting and tree height so no later pass can exhaust the host stack.
- `src/Resolver.zig` is name resolution: scopes, declarations, hoisting, and the section 6.1
  rules. These belong here rather than in the interpreter because they are properties of
  the text rather than of a run. It also records, per function, which module variables it
  reads and which functions it calls, for the checker.
- `src/Type.zig` is the static type representation, its compatibility rules, function
  signatures, and the list method table the checker and interpreter share.
- `src/Checker.zig` is type checking and flow analysis: inference, annotations, operand
  errors, section 4.1's definite assignment, and everything section 7 asks of functions.
- `src/Value.zig` holds `Nothing`, `Bool`, `Int`, `Float`, and lists, implements section
  9.4's display rules, and compares and orders values.
- `src/Heap.zig` owns list buffers, string texts, scope environments, closures, and struct
  instances: reference counts, copy-on-write, and section 19.5's mark-and-sweep collector,
  which walks the lists of every live object and reclaims the cycles counting cannot.
- `src/unicode.zig` is Emerald's Unicode: grapheme clusters (UAX #29), NFC normalization
  and its quick check (UAX #15), full case mapping with Final_Sigma, and identifier and
  whitespace classes. Its data is `src/unicode/tables.zig`, generated from Unicode 17.0.0
  by `tools/unicode/generate.zig`; `src/unicode/test/` embeds Unicode's conformance data.
- `src/strings.zig` holds section 9's string operations on UTF-8 bytes: character-aware
  searching, splitting, trimming, substrings, and strict number parsing.
- `src/Interpreter.zig` evaluates, applying section 5.3's result types and failure modes,
  and guards the host stack. Block and call scopes come from the general allocator and are
  reused once emptied, so a running loop does not allocate.
- `src/emerald.zig` is the library root. `check` and `run` share one pipeline that stops at
  the first stage to report anything, which is section 17.2's rule against cascades. The
  pipeline runs on a thread with a large reserved stack.
- `src/main.zig` implements `emerald check`, `run`, `format`, `test`, `repl`, and `lsp` with
  the section 18.1 exit codes (`2` for an uncaught runtime error, `3` for a test failure,
  `70` for an internal failure). It chooses the fast `smp_allocator` outside Debug builds.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `lexical/` must tokenize cleanly, `diagnostics/` must match their `.expected` exactly,
  `run/` must print theirs, `runtime-errors/` must fail with theirs, and `format/` must
  come back exactly, with formatting that output again a no-op. See
  [conformance/README.md](../conformance/README.md) for how to add one.
- `src/Formatter.zig` is section 18.3's canonical formatter, `src/Repl.zig` is section
  18.4's `emerald repl`, and `src/Lsp.zig` is section 18.5's `emerald lsp` (its first slice —
  see "Next step" for what its second slice needs). `docs/journal.md`'s "Slice 15
  completion" section has how each was built, including every non-obvious bug found along
  the way.

## Deferred

Cross-checked against the binary in this pass; two stale entries (range values, and `?.`
object/property reads) were removed because both have since shipped.

- Assignment through a call's result, as in `find().score += 1`. Changing methods already
  work on a temporary, but assignment is checked from a named root; `const found = find()`
  first is the way to write it.
- Displaying more than 256 objects nested inside one another shows the innermost as
  `Name(...)`, the same notation as a cycle, since the display stack is fixed.
- A call inside a block written at module level is not checked against module variables not
  yet assigned, since the block may run later; the runtime reports the read as unassigned.
- Taking `Trait.method` as a value (rejected with a message for now).
- The warning for a type test whose answer is known before the program runs (`x is Int`
  when `x`'s declared type is already `Int`), which needs diagnostics with a severity.
  Confirmed still absent this pass: the test evaluates and returns the right `Bool` with no
  extra diagnostic.
- Capturing a built-in method such as `numbers.append` (7.4 says every method is capturable,
  with an expected type for `numbers.map`), variadics, and capturing a built-in function
  such as `print`, which no written function type describes.
- A bare top-level `return` (14.1 describes it ending the program) is rejected outside a
  function today. Confirmed this pass: `` `return` can only be used inside a function ``.
  `Program.arguments` (15.2/24) is likewise unimplemented — no trace of it anywhere.
- The warning for unreachable code after a `return`. Diagnostics have no severity yet; until
  they do, code after two branches that both return is treated as assigned everything
  rather than reported.
- Section 6.2's `if ... then ... else` expression is unaffected by this; `unless` is not a
  keyword and never will be.
- `List`/`String` range-slicing (`text[1..<4]`, `list[1..<3]`) and its omitted-endpoint
  forms fail to parse/type-check — confirmed directly against the binary while writing the
  library reference pages. `letter?`/`digit?` (general category tables), and `words`,
  `title_case`, and case-insensitive Unicode comparison, need a dedicated locale and
  boundary design pass first.
- `remove_if` on `List` (removing every value matching a block) does not exist, despite
  being named as design intent in 8.5's prose.

## Review findings still open

An adversarial review of the fieldless-struct and required-fields slices (`7214005^..ed868a4`)
found several defects, all since fixed (`1850085`, `72e7df4`) and the argument-checking
duplication it originally also listed has since been retired by a later chunked review. The
remaining items are maintainability work, not reproduced behavioral failures, and have not
been re-verified against current source in this pass:

- **Struct field lookup is hand-written twice instead of resolved once.** `evaluateProperty`
  (`Interpreter.zig`) and `typeOfMember` (`Checker.zig`) each independently scan
  `descriptor.fields`/`user.fields` by name with their own `std.mem.eql` loop. A tuple
  position is resolved once, by the parser, into a numeric `Member.position`; a qualified
  name is resolved once, by the resolver, into `Facts.qualified`. A struct field never got
  the same treatment, so correctness depends on the checker's scan and the interpreter's
  scans (`fieldPosition`, used by reads, stores, and `containerSlot`) agreeing by
  construction rather than by sharing one answer. Since properties arrived, a name the
  interpreter's scan misses is read as a property, so a divergence (case sensitivity,
  Unicode normalization) would now fail on a missing property rather than an `unreachable`.
  Worth resolving a member to its field position or accessor once, before the object model
  grows further.
- **Struct equality duplicates the tuple/list sequence-equality pattern.** The
  `.struct_value` case in `Value.equals` — descriptor-identity check, then a paired loop
  calling `equals` recursively and stopping at the first mismatch — is structurally
  identical to the `.tuple` case immediately above it, and to `.list`'s. A small
  `equalsSequence(gpa, a, b)` helper would remove the third copy.
- **Struct field parsing duplicates parameter parsing.** `parseParameter` parses "name →
  require `:` → `parseTypeExpression()` → optional `= default`", and `parseStructMember`
  repeats the same sequence by hand for a stored field, with its own messages. Defaults
  arrived for both at once, so they have not diverged yet, but a change to one (a new
  annotation form, say) has to be made twice.
- **Every parsed type annotation now allocates, even without a namespace path.**
  `parseTypeExpression` used to return a zero-copy slice straight from source text in the
  common case (`Int`, `String`, an element type with no `.`). This slice's qualified-path
  handling unconditionally builds an `ArrayList(u8)` and copies the name into it before
  checking whether a `.` ever follows, so every parameter, return type, variable annotation,
  and now every struct field pays an allocation it did not need before. Start the list only
  once a `.` is actually seen.
- **`check()` scans every statement four times to find struct declarations.** Four separate
  `for (programs) |program| for (program.statements) |statement|` loops each refilter
  `statement.data == .struct_declaration` — for identity and hoisting, field resolution,
  dictionary-key eligibility, and the final pass over bodies. Collecting matches into a flat
  list on the first pass and iterating that list afterwards would filter once.

## Known rough edges

- Interpreter-detected failures currently use the common `RuntimeError` type. Grow the
  hierarchy with the feature that produces each failure instead of designing it all at
  once. The first existing requirements to reconcile are `RecursionError` in section 7.2
  and `InputError` in sections 2 and 15.2; later conversion, filesystem, regex, and network
  work should add its specific error types in the same implementation slice.

- **A literal mixing sibling classes needs its type written.** `[Dog(), Cat()]` is reported
  as a list holding `Dog`, since inference never looks for a common base class; `const pets:
  List[Animal] = [Dog(), Cat()]` works. A common-base rule would need designing with `if`
  branches and `or`, which infer the same way.

- **What a block assigns is recorded by bare name.** `Facts.assigned_in_lambda` holds names,
  not bindings, so a lambda or nested function assigning its own `text` stops narrowing of
  every `text` in the program, and changes that one's help to say a block could set it back.
  Conservative, never unsound.

- **A long chain of calls between top-level functions is slow to check.** 2,000 functions
  each calling the next take about 2 s in ReleaseSafe.

- Assigning to a type-level field through its namespace, `Shapes.Circle.made = 1`, is
  reported as "`Shapes` is a namespace, not a value"; reading and calling through the
  namespace work, and `using Shapes` then `Circle.made = 1` works. Assignment through a
  namespace was never supported for module bindings either, so the two should be lifted
  together.
- The capture check over-approximates type setup: constructing a type counts what every
  type-level field's value reads even after the type is set up, and reading one field
  counts all of them. Moving the use below the assignment always works.

- The capture check counts what a default reads even when the call supplies that argument,
  so `Box(width: 2)` above the assignment of a module variable only `width`'s default reads
  is reported. Moving the call down always works. Tracking default reads separately, per
  parameter, would remove the false report.

- Reaching a receiver while its changing method runs is caught only at runtime. The common
  case — the method, or a function it calls, reads the module variable it was called on — is
  visible to the capture facts and could become a `check` diagnostic.

- `invoke` restores a changing receiver and releases its inputs for every Emerald error and
  for the recursion limit. A host allocation failure while it is still constructing the
  call frame can leave some argument counts high until the interpreter heap is torn down.
  Host allocation failure stops the run and cannot be caught by Emerald, so this is not
  observable language behavior, but the ownership path should be made fully transactional
  when `Interpreter.zig` gets its own `checkAllAllocationFailures` coverage (see "Next
  step" — the frontend already has this, `invoke` does not).

- Recursive dictionary-key eligibility currently keeps a fixed path of 256 struct types.
  A cycle is correctly rejected, but an acyclic chain deeper than 256 is conservatively
  rejected too. Ordinary programs will not approach this; replace it with checker-owned
  visitation state if generated code ever does.
- The capture check is conservative. It flags a call if the callee could read an
  unassigned variable on any path, even one this particular call cannot take. Moving the
  call below the variable is always the fix, and the diagnostic says so.
- Definite assignment at the top level does not see assignments made inside a called
  function. `var total: Int`, then a call to a function that sets it, then a read, is
  rejected as possibly unassigned. Initializing the variable is the fix.
- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.
- Indexing a string by character is linear, as section 9.1 accepts, so
  `for i in 0..<s.count { s[i] }` is quadratic. `for character in s` is the linear way, and
  a cached boundary index is the fix if real programs need it.
- A string's searching methods return text built from the normalized haystack when the
  haystack was not already NFC, so `replace` on decomposed text yields composed text.
  Canonically this is the same string, but the bytes differ from the input.
- A multi-line block comment joins the lines around it rather than terminating a statement,
  matching how C-family languages treat their block comments.
- Closures in a loop no longer grow memory. The same measurement that showed 155 MB for
  200,000 iterations of `const block = { => i }` before the collector now shows 3.4 MB, and
  the program got faster rather than slower (0.09 s against 0.17 s) because it allocates
  less. The threshold is 4,096 live objects, doubling to twice the surviving count after
  each collection.
- Removing an entry from a dictionary or set rebuilds its index table, so removing many
  entries one at a time is quadratic in the size of the collection. Insertion order is
  what makes this the simple choice — the entries are an array, so a removal shifts every
  later one. A tombstone scheme would fix it if a real program ever notices.
- Narrowing does not cross `or`. `if value == nothing or score > value` is rejected, while
  the same test written as `if`/`else` is accepted. Section 4.5's narrowing is applied to
  branches and loop bodies but not to the right operand of a short-circuiting operator,
  where the left operand's falsity is also a proof. The diagnostic it produces is worse than
  the gap: it says "`>` needs numbers, but these are Int values", which names the payload
  type rather than the optional.
- The capture check does not follow a function reached through a value. `const f = later`
  then `f()` above a module variable `later` reads is not reported the way a direct call is;
  the interpreter's unassigned-read error catches it at runtime instead. Extending
  `checkCaptures` to callable values would need the checker to track which function a
  variable holds.
