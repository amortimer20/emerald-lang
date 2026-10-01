# Editor intelligence: design and implementation plan

Status: accepted, 2026-10-01. The user accepted all ten recommendations. Claude builds it. Implementation
starts after the REPL work's slice 2 is merged, since both touch the compiler's front end; until
then only this plan changes.

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
- Settled while building: (record here)

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
- Settled while building: (record here)

### Slice 3: Hover and documentation

- Hover shows a signature, the summary, what it can raise, and for built-ins a link to the
  website's member anchor (decision 6). For a declaration with a `##` comment, the comment.
- The checker's "did you mean" hints read the data's names, so a new member never needs adding twice.
- Settled while building: (record here)

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
