# Editor intelligence: design and implementation plan

Status: accepted, 2026-10-01. The user accepted all ten recommendations. Codex implements
slices 1-6, one at a time; Claude reviews and handles website parity in slice 7. The REPL
is merged, so its former implementation prerequisite is satisfied.

The goal is the editing experience a student gets in C#: type a dot and see everything the value
can do, with what each thing takes and gives back and one plain sentence about it; hover over a
name and see the same; and get help with a call's arguments while typing them. The executor makes
the remaining judgement calls within a slice and records each under that slice's "Settled while
building" note. At the start of each slice, reread `git status`, the recent `git log`, and
docs/handoff.md.

## What is there now (checked against main `83f9119`, 2026-10-01)

Measured by speaking JSON-RPC to `emerald lsp --stdio`:

| Typed | Today | Should offer |
| --- | --- | --- |
| `s.` for a `String` | nothing | `upper`, `split`, `pad_start`, and the rest |
| `xs.` for a `List[Int]` | nothing | `append`, `map`, `filter`, `sort`, and the rest |
| `n.` for an `Int` | nothing | `abs`, `times`, `to_string`, and the rest |
| `Math.` | nothing | `pi`, `sin`, `power`, and the rest |
| `Date.` and `d.` for a `Date` | the right members | the same, with signatures and a sentence each |
| `Ma` (a bare name) | 50 names, without `Math`, `Program`, or `String` | those too |
| hover on `"abc".upper()` | `String` | `upper(): String` and "The text in capital letters." |
| go to definition on `Math.sin` | nothing | (see decision 6) |
| typing `pad_start(` | "method not found": no signature help | `pad_start(width: Int, fill: String = " ")` with `width` highlighted |

Every completion item is a bare label: no kind (method, property, type), no signature, no
description. The server advertises completion, hover, definition, references, rename, symbols,
and formatting, but not signature help or code actions.

Why the gaps exist:

- **Native members have no declarations.** `String`, `List`, `Dict`, `Set`, `Int`, `Float`,
  `Bool`, `Range`, `Bytes`, `Tuple`, `Math`, and `Program`, about 230 members, are typed by tables
  in `Type.zig` (`string_methods`, `list_methods`, `int_methods`, `float_methods`,
  `math_functions`, and `map_methods`, which is only a set of names) plus about 130
  name checks inside `Checker.zig` (`map`, `each`, `filter`, `reduce`, `union`, `to_hex`, and
  others with blocks or unusual types). Completion and hover only know declarations, so they
  see none of these. Types written in `src/prelude.em` (`Date`, `File`, `Json`, `Console`, and the
  rest) are real declarations, which is why they complete.
- **Nothing anywhere has a description.** The tables hold parameter kinds without names, and
  `prelude.em` has no `##` comments. Hover shows an expression's type and never a declaration's
  `##` text, for user code either (already a recorded rough edge).
- **Completion analyzes the whole project twice per keystroke.** `foo.` does not parse, so the
  server patches a copy of the buffer with a fake `placeholder()` call and runs the full analysis,
  then for a type or namespace patches it again and runs it a second time.

## What a student should see

```text
const name = "Ada"
name.|                       ← a list opens:
    upper()      String        The text in capital letters.
    pad_start()  String        The text with fill added at its start until it is width long.
    split()      List[String]  The pieces of text between each separator, in order.
    count        Int           How many characters the text has.
    ...

name.pad_start(|             ← a hint appears:
    pad_start(width: Int, fill: String = " "): String
              ^^^^^^^^^^
    The text with fill added at its start until it is width characters long.

hover on Math.sin:
    Math.sin(radians: Float): Float
    The sine of an angle in radians.
    Read more: emerald-lang.web.app/docs/library/program/math/#sin
```

## Principles

1. **One description per member, read by everything.** Completion, hover, signature help, the
   checker's "did you mean" hints, and checks on the website all read the same data, so they can
   never disagree.
2. **The compiler stays the authority on types.** The data describes members for people; a test
   proves it names exactly the members the checker accepts, with the same shapes. No second type
   system appears (18.5).
3. **Written for learners.** Summaries are one plain sentence in the website's voice, not the
   maintainers' reference prose.
4. **Fast enough to feel instant.** One analysis per request, at most; measured.

## Decisions for the user

All ten were accepted as recommended on 2026-10-01. The alternatives are kept for the record.

1. **Where the descriptions live (recommended: two places, one per kind of member).** Natively
   typed members (the ~230 above) get a data file in emerald-lang, `src/builtins.json`, with each
   member's owner, name, form (method, property, function, constant), signature as a reader sees
   it, one-sentence summary, and flags (changes its receiver, optional result, takes a block,
   can raise). Members already written in Emerald, in `prelude.em` and in a student's own code,
   get their description from an ordinary `##` comment above the declaration, which hover then
   shows. So `Date.today()`, `greet()` in a student's file, and `String.upper()` all show a
   sentence the same way.
   Alternatives: write every built-in, natives included, as Emerald declarations in a stub file,
   which needs syntax the language doesn't have (generic methods such as `map` from `T` to `U`; 11.3
   defers user generics); or pull text from docs/library, whose prose is written for maintainers
   and isn't uniform enough to extract one sentence from.
2. **Who writes the summaries, and in what voice (recommended: Claude writes them in the
   website's voice, starting from each member's first sentence on its reference page).** Those
   sentences are already plain and learner-facing (`upper`: "The text in capital letters."), and
   the user has read them. Alternative: maintainer wording from docs/library.
3. **The website stays hand-written, with a parity check (recommended).** A script in
   emerald-website compares each built-in page's `<Member>` names with `builtins.json` and fails on
   a member missing from either. Alternative: generate the reference pages from the data, which
   would replace the slow, deliberate learner pages the user asked for.
4. **What choosing a completion inserts (recommended: a method inserts its name with
   parentheses).** `upper` inserts `upper()` with the cursor after it; `pad_start` inserts
   `pad_start()` with the cursor inside, and signature help appears. A property such as `count`
   inserts just its name. This reinforces that calls always have parentheses, one of the homepage's
   promises. Alternative: insert only the name, as some editors do.
5. **Error-tolerant parsing comes later, in its own plan (recommended).** Replacing the
   `placeholder()` patch with a parser that keeps an unfinished `foo.` is the right long-term
   structure, but it changes the parser every tool uses. This plan keeps the patch and cuts each
   request to one analysis, and measures the time. Alternative: do it now, inside this plan.
6. **Go to definition on a native member opens nothing, and hover links to the website
   (recommended).** A native member has no source to jump to. Alternatives: open a generated,
   read-only stub file; or open the website page from definition, which surprises people who
   expect definition to stay in the editor.
7. **Signature help is in this plan (recommended),** for built-ins and the student's own functions,
   with the active parameter highlighted, named and default arguments shown. Alternative: later.
8. **Quick fixes start with "did you mean" only (recommended).** When a diagnostic already
   suggests one exact replacement (a misspelled name or member), the editor offers it as a one-click
   fix. Others, such as `&&` to `and` or adding `with Trait`, wait until their diagnostics give
   the hint (recorded rough edges). Alternative: no quick fixes in this plan.
9. **The extension shows which Emerald it is using (recommended).** The output channel's first
   line names the `emerald` binary and its version, and the status bar shows `Emerald 0.7.0`.
   If the binary is missing, the existing error stays. Alternative: output channel only.
10. **The grammar colors built-in namespaces and error classes (recommended: yes, as
    `support.class.builtin.emerald`).** `Math`, `File`, `Json`, `RuntimeError`, `FileError`, and the
    rest get the same scope family as `String` and `List`, so they read as part of Emerald in every
    theme. Because highlighting is lexical, a student's own `File` struct would also be colored as
    built-in; that is rare, and the checker already warns about it where it matters. Alternative:
    leave them as ordinary type names. The website's highlighting follows the grammar, so it
    changes too.

## Slices

Each slice ends with the validation below passing, and one commit or a short series. The language
server's slices go to emerald-lang; slice 6 is in emerald-vscode; slice 7 is in emerald-website.

### Slice 1: The member data, proven against the checker

- `src/builtins.json` with every natively typed member (decision 1), loaded once when the server
  starts and when the checker needs a hint.
- A drift test: for each owner, the names in the data equal the names the checker accepts, and
  each entry's parameter count, block, and result agree with the checker's table or branch. Names
  the checker handles in a branch rather than a table are listed beside the branch, so the test can
  enumerate them.
- `##` comments for the members declared in `prelude.em` (decision 1), in the same voice.
- No behavior change for programs; existing tests pass unchanged.
- Settled while building (the data half, 2026-10-01, on `claude/builtin-data`; the drift test
  waits for REPL slice 2):
  - `src/builtins.json` has 241 members and 244 signatures, bootstrapped from the website's
    `<Member>` entries, which the user has read, and then edited by hand; from now on the JSON is
    the source and the website is checked against it (slice 7). A member has `owner` (`null` for
    a prelude function), `name`, `kind` (`method`, `property`, `type_method`, `type_property`,
    `function`, `statement` for `assert`), `changes` when it changes its receiver, and a list of
    `signatures`, since `substring`, `up_to`, and `down_to` each have two shapes. A signature has
    `parameters` (name, type, `default`, `optional`, `variadic`), an optional `block` as written,
    `result`, `summary`, `raises`, and `page`.
  - Besides the twelve native types and namespaces, `Task`, `TaskGroup`, `Channel`, and `Random`
    have native methods (`result`, `start`, `send`, `next`, and the rest) behind bodiless prelude
    classes, so they are in the data too.
  - Where the checker lists every member in its "has no member" hint (`String`, `Int`, `Float`),
    the data matches it exactly. Its hints for `List`, `Dict`, and `Set` show only a sample, so the
    drift test is the real proof.
  - `prelude.em` has 181 new `##` comments, one above each public declaration a website page
    describes. Not commented: the operators (`duration + other`), which are not named
    declarations; `Json.Kind`'s values, which share one line; and each error's `message`, which
    is `Error.message`, inherited.
  - Comparing the prelude's parameter names with the website found `File.write` and
    `File.append` documented with `text` where the declaration says `contents`, so
    `File.write(path, text: ...)` from the page was refused. The website now says `contents`.
  - Slice 1 implementation started on `codex/editor-intelligence` from main `b728612`
    (2026-10-03), but stopped at a verified checker mismatch, as the brief requires.
    `List.chunks` and `List.windows` produce `List[List[T]]`, and `List.pairs` produces
    `List[(T, T)]`; the data, reference, and interpreter agree. The checker instead gives
    all three `List[T]`: their `Type.list_methods` entries use `.result = .list`, and
    `typeOfMethodCall`'s generic result path wraps the original element type once.
    A freshly built binary rejects correctly annotated results for all three, while
    unannotated calls print the nested lists and tuple pairs. No checker or data change
    was made; approval to correct the checker is needed before the drift test can pass.
  - The user approved the three result corrections and regressions. Before changing
    their types, the completed result test compared every catalog signature's inferred
    result, with distinct substitutions for generic input/output types. Its only real
    result mismatches were `List.chunks`, `List.windows`, and `List.pairs`. The table now
    distinguishes list, nested-list, and pair-list results. Run and diagnostics cases
    cover correct uses and formerly accepted wrong annotations for each method.
  - The loader is owned once by the LSP server; ordinary execution never loads the
    catalog. Name inventories for special branches sit beside those branches. Tests
    check names in both directions, inferred block parameter types, optional/default
    omissions, variadic calls, required blocks, and rejected arity boundaries.
  - Name parity found a missing `String.to_bytes` data entry, now added with a plain
    summary and a link to the existing Bytes conversion section. The original 241/244
    totals above are historical; the catalog now contains 242 members/245 signatures.
    The universal `type_name` property is also absent from the original catalog;
    its treatment needs clarification, especially for Tuple, which otherwise has no
    named members. No universal-property exception has been declared settled.
  - Arity-boundary testing exposed a separate checker crash: `Range.step()` ignores
    `requireArity`'s false result and reads absent `call.arguments[0]`. A minimal real
    `emerald check` probe also aborts. Stopped for approval rather than fixing this
    outside the approved result-type corrections or excluding it from the test.
    Pinned toolchain and native build passed; the website List page passed all 49
    examples unchanged. Debug validation is not green (the arity test crashes).
    Remaining gate, extension integration, commit, push, and CI are still pending.
  - The user approved the Range crash fix and the universal-property representation.
    `Range.step` now stops after a failed arity check, preserving the existing diagnostic
    wording; `range-step-missing-argument` is its regression. `type_name` has one entry
    with owner `"*"`, a universal note in `about`, and the exact website path the user
    supplied. Its result is checked on every native value owner, plus struct, class,
    enum, tuple, callable, optional, and `nothing`; types and namespaces are rejected.
    The catalog now contains 243 members and 246 signatures.
  - Added a separate exhaustive boundary test: every catalog member is checked with
    zero arguments and one more than its largest ordinary parameter list. Valid
    zero-arity/default/variadic calls are required to remain valid; calling a property
    requires a diagnostic. Required blocks are omitted in this test, while the drift
    tests separately exercise valid blocks and inferred block parameter types.
    After the Range fix, the complete sweep found no additional crashes, but four
    missing diagnostics: `Math.pi()`/`Math.e()`, with zero or one argument, are silently
    accepted despite being constants. Requested approval to use the existing Float
    constant-call diagnostic; did not hide these failures or change that behavior yet.
  - The user approved the Math correction. Both resolved Math constant keys now use
    the existing Float constant-call branch, regardless of argument count. This
    prevents a checked call from reaching the interpreter as though a Float were a
    closure. `math-constants-called` checks `Math.pi()`, `Math.pi(1)`, and `Math.e()`
    with the exact approved wording; its expected output was read by hand.
    The boundary test calls every property in the catalog, including all type-level
    constants (`Float.infinity`, `Float.nan`, `Math.pi`, `Math.e`, `Program.arguments`),
    with zero and excessive arguments. No owner-specific exemption is made.
  - Final validation passed on pinned Zig 0.16.0: Debug and ReleaseSafe
    `zig build test -j1`, native `zig build -j1`, documentation examples (24 executed,
    135 conformance links), changed-Zig formatting, whitespace checks, and Windows
    and macOS cross-builds with separate prefixes. The List website page passed all
    49 examples unchanged; VS Code integration passed all 9 tests against this server.
    Slice 1 was committed as `eebe5e7` and pushed. CI run `37128949445` passed all seven
    jobs (Linux/macOS/Windows Debug and ReleaseSafe, plus bounded execution fuzzing).
    Stopped for slice 1 review; no slice 2 work started.

### Slice 2: Completion

- After a dot: every member of a value's type, native or declared, and every member of a type or
  namespace written before the dot, including `Math` and `Program`. Private (`_`) members of other
  types are left out, and so is anything the checker would refuse at that place, such as a
  type-level member on a value.
- Each item has its kind, its signature as detail, and its summary as documentation; methods insert
  with parentheses (decision 4).
- Bare names include `Math`, `Program`, and the built-in type names.
- One analysis per request (decision 5), not two; time a completion in the largest example project
  before and after, and record both.
- An LSP test category, `conformance/lsp/`: each case is a document, a request at a marked
  position, and the expected response, run through the real server.
- Settled while building (2026-10-03; completed):
  - Kept the placeholder approach, but added a tool-analysis entry point that retains
    parsed declarations and resolver facts when its synthetic member fails resolution.
    It never checks failed resolution or treats that partial analysis as executable.
    Values and type/namespace paths therefore share one analysis, without changing the
    parser or resolver. Compiler-token delimiter closing preserves existing suffixes
    and ignores quoted/commented delimiters; completing inside an existing identifier
    also preserves its call rather than producing a second one.
  - `Completion.zig` owns presentation and allocation only. Native names/signatures/
    summaries come from the catalog; declarations and attached comments come from
    retained source. Receiver parameters are substituted where known, while a future
    block's result stays symbolic. Prelude-qualified type spelling is displayed without
    its implicit namespace; optional markers are included even though annotation spans
    exclude the final `?` in the AST.
  - Kept receiver eligibility and changeability in the checker, where the scopes and
    existing place-resolution rules are available. Changeability facts are computed
    only for completion analysis; normal checking and execution do not do that work.
    Completion omits changing methods on frozen/temporary value receivers, incompatible
    List aggregations/conversions, and private members outside their owning braces.
    Tuple positions come from the checked tuple type, not a parallel member inventory.
  - The existing `.or(fallback)` method was absent from slice 1's catalog/inventories.
    Added owner `Optional` as a receiver category, not a new language type, and extended
    bidirectional/result/arity tests. The catalog now has 244 members and 247 signatures.
    Primitive bare names read Type.fromName's shared table; there is no invented `Any`,
    `Tuple`, or `Optional` named type in completion.
  - Added 40 framed-server cases, including every original table row. Hover, native
    definition, and unsupported signature help record their unchanged pre-slice-3/4
    behavior; completion cases cover all native receiver kinds, const/mutable and
    element-type restrictions, inheritance/privacy, nested aliases, namespace/type
    shadowing, optional chaining, source documentation, and preserved editor suffixes.
    Replies are reviewed JSON, not automatically blessed. Both the conformance runner
    and the standalone protocol tool run each case 50 times.
    Unannotated functions use checked return signatures when available, including
    nested functions. A partial resolver-only analysis displays `(inferred)` rather
    than guessing `Nothing` when no return annotation or checked result is available.
  - Main through `6020d13` was merged without discarding its new pre-compiler roadmap.
    ReleaseSafe completion medians on the largest example project (`examples/ledger/main.em`)
    were 7.426 ms before and 3.022 ms after for `File.` (15 items both), and 10.153 ms
    before and 5.244 ms after for a String receiver (0 items before, 38 after), over 25
    requests after five warmups; startup and document-open diagnostics are excluded.
  - Source review found five checker-special typed calls whose prelude stubs cannot
    describe their real signatures: `Json.encode/decode`, `Csv.encode/decode`, and the
    struct-row `Console.table` form. Added their editor signatures to the shared catalog,
    checker-adjacent name inventories, and a direct LSP regression. Ordinary result/arity
    probe generation skips these calls because their shape comes from dedicated checker
    branches, not the written stub. No language or runtime behavior changed.
  - Debug and ReleaseSafe `zig build test -j1`, native build, doc examples, formatting,
    diff check, Windows/macOS cross-builds, and all 40 standalone LSP cases at 50 requests
    each passed. One VS Code integration run timed out in format-on-save after its other
    eight tests passed. The user reported seven successful runs from Claude; a subsequent
    run here completed all nine tests successfully. The timeout was transient, not a
    completion regression. Slice 2 was committed as `3868394`, pushed, and branch CI
    passed all seven jobs in run `37147012161`. At the next slice boundary, main's three
    documentation-only roadmap commits were merged without conflict in `49eef58`;
    slice 3 works from that merged state.

### Slice 3: Hover and documentation

- Hover shows a signature, the summary, what it can raise, and for built-ins a link to the
  website's member anchor (decision 6). For a declaration with a `##` comment, the comment.
- The checker's "did you mean" hints read the data's names, so a new member never needs adding twice.
- Settled while building (2026-10-03):
  - Hover replies use Markdown: a fenced Emerald signature, the learner-facing summary,
    and a website link for members represented in the catalog. Catalog entries marked
    `raises` add the neutral note “May raise an error.” because the catalog records only
    whether a failure is possible, not a checked error type. Prelude declarations outside
    the catalog use their `##` text and source signature; Emerald has no raises effect
    on source declarations, so hover does not infer one from implementation details.
  - For catalog entries, the catalog is preferred to its prelude stub so typed-special
    signatures and docs stay aligned with completion. User/project declarations use the
    resolver-selected source target, including a method's own `##` comment and inferred
    return type. Hover on the declaration name itself is supported as well as on a use.
    Native members still have no go-to-definition target.
  - Checker synonym corrections retain their curated cross-language aliases, but a
    method/property correction is offered only if its target name exists in the catalog;
    dictionary indexing corrections (`[key]` and `[key] =`) remain syntax-based. The
    learner-oriented unknown-member help is hand-written for List, Dict, Set, String, Int,
    and Float. List and dictionary-indexing guidance stays explicit, while String, Int, and
    Float sample about ten useful names and point to their references. A checker test
    extracts every backticked member and confirms it exists in the catalog; universal
    `type_name` is intentionally omitted. The catalog remains the authority for synonym
    suggestions.
  - Prelude-declared library types and their members link through a top-level `type_pages`
    map in `src/builtins.json`; member links strip a trailing `?` or `!` for the website
    anchor. File and Path hover cases cover these links. Prelude declarations do not carry
    machine-readable raises metadata, so a possible-raise note for them is follow-up work,
    not part of this correction.
  - Added Markdown hover coverage for an instance method, a raising Bytes conversion,
    a namespace function, a prelude function, a program function both at its use and
    declaration, and universal `type_name` on native and user-defined values. All 48
    real-protocol LSP cases pass 50 requests each; existing native
    definition remains empty. No language/runtime behavior changed.
  - The pinned-toolchain full gate passed: Debug and ReleaseSafe `zig build test -j1`,
    `zig build -j1`, documentation examples, changed-file formatting, whitespace, and
    Windows/macOS cross-builds. The VS Code suite first timed out in format-on-save after
    eight passes. Three runs in this environment timed out at that same test. Direct
    `textDocument/formatting` requests returned the expected `const x = 1` edit for both
    file and untitled URIs. The user reports Claude ran the suite successfully seven times.
    The downloaded VS Code logs an unavailable `native-keymap` module. No extension files
    changed. Slice 3 was committed as `8fac992`, pushed, and CI run `37153243148`
    passed all seven jobs. The integration UI timeout remains recorded as an environment/test
    harness discrepancy, not a server-formatting failure; the requested slice did not change
    formatting or the extension. emerald-vscode PR #3 changes that test to apply edits by
    document URI. After PR #3 merged as `597d066`, the integration suite passed all 9 tests
    against the pushed Emerald server.
  - Review correction: restored the learner-oriented List, Dict, and Set help, and replaced
    the stale exhaustive String, Int, and Float lists with useful samples. The backticked
    member names are checked against the catalog in a unit test; dictionary `[key]` is the
    one intentional syntax example rather than a member. Added type-page routes for the
    prelude library surface, with `?`/`!` removed only from member anchors; File and Path
    protocol cases cover the links. A possible-raise note for prelude members remains a
    follow-up because these declarations do not carry raises metadata. Corrected the handoff
    and journal attribution for website parity: slice 7 belongs to Claude.
  - Correction validation: Debug and ReleaseSafe `zig build test -j1` each passed 558/558
    tests; all 51 real-protocol LSP cases returned identical replies 50 times. The native
    build, documentation examples, formatting, whitespace, and Windows/macOS cross-builds
    passed. After emerald-vscode PR #3 merged, `npm run test:integration` passed all 9 tests
    against this server. The correction was committed as `052ebda`, pushed, and CI run
    `37161858942` passed all seven jobs.

### Slice 4: Signature help

- `textDocument/signatureHelp` (decision 7), triggered by `(` and `,`: the callee's parameters with
  the active one marked, defaults shown, and named arguments matched by name. Built-ins, the
  student's own functions and methods, and constructors.
- Settled while building: (record here)

### Slice 5: Quick fixes

- `textDocument/codeAction` for diagnostics that suggest one exact replacement (decision 8). The
  diagnostic carries the replacement as data, so the editor never parses message text.
- Settled while building: (record here)

### Slice 6: The extension (emerald-vscode)

- The binary and version in the output channel and status bar (decision 9).
- Grammar scopes for built-in namespaces and error classes (decision 10), with tests, following
  the extension's AGENTS.md (keep it lexical, standard scopes).
- Release notes for 0.3.0; the user publishes.
- Settled while building: (record here)

### Slice 7: The website (emerald-website)

- The parity check (decision 3), run with the other page checks.
- If the summaries changed any wording, carry it back to the pages' "At a glance" lines so the
  editor and the site say the same thing.
- Settled while building: (record here)

## Validation

Slices 1 to 5, on the pinned Zig 0.16.0 with `-j1`: Debug and ReleaseSafe `zig build test`, `zig
build`, `tools/check-doc-examples.sh`, `zig fmt --check` on changed files, `git diff --check`, and
the Windows and macOS cross-builds; plus the extension's integration suite (`npm run
test:integration` in emerald-vscode), which drives a real VS Code against the built server. Slice
2 onward also runs `conformance/lsp/`. Slice 6 runs the extension's `npm test`, `npm run package`,
and the integration suite; slice 7 the website's page checks and build.

## Open questions

- The user once saw red "not defined" errors in the editor that could not be reproduced. An
  example (the message, the line, and whether the file is in a project) would let slice 2 cover it.

## Out of scope

- Error-tolerant parsing (decision 5): its own plan.
- Semantic highlighting from the checker, inlay type hints, code lens, and the debugger (18.6).
- Completion that ranks by likely use; items are sorted by name.
- Editors other than VS Code; the server stays editor-independent, so they work through any LSP
  client, untested.
