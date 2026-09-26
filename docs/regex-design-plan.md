# Regular expressions: design and implementation plan

Status: complete, 2026-09-26; all six slices done. Rewrite-context 15.4 settles the API's outline. This plan fills
in what 15.4 leaves open (where the matching engine comes from, what `.` and `\d` mean in a
language whose characters are graphemes, captures, replacements, and errors) and orders the
work. The decisions below are recommendations; the executor proceeds with them unless the
user overturns one. Read AGENTS.md and the current handoff before acting, and at the start of
each slice reread `git status`, the recent `git log`, and docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally, and none should be able to
hang, however unlucky the pattern:

```emerald
# Is this a valid code?
const code = Regex('[A-Z]{3}-\d{4}')
if not code.matches?(input("Ticket: ")) {
    print("Tickets look like ABC-1234")
}

# Pull every number out of a line.
const numbers = Regex('\d+').find_all("3 apples, 12 pears").map { found => found.text.to_int() }
print(numbers.sum())                      # 15

# Split on any run of commas and spaces.
print(Regex('[,\s]+').split("red, green,blue"))       # ["red", "green", "blue"]

# Read the parts of a date written the American way.
const us_date = Regex('(?<month>\d{1,2})/(?<day>\d{1,2})/(?<year>\d{4})')
const found = us_date.find("Due 9/25/2026")
if found != nothing {
    print(Date(found.named("year").to_int(), found.named("month").to_int(), found.named("day").to_int()))
}

# Tidy text.
print(Regex('\s+').replace_all("too    many   spaces", " "))
print(Regex('\d+').replace_each("3 apples") { found => (found.text.to_int() * 2).to_string() })
```

## Principles

1. **No pattern can hang a program.** Matching takes time proportional to the pattern times
   the text, always. Backtracking engines (PCRE, Python's `re`, JavaScript) can take
   exponential time on patterns such as `(a+)+$`; a beginner cannot be expected to know
   which patterns do, and a hung program teaches nothing. This is the property Go, Rust,
   and RE2 chose, and it rules out backreferences and lookaround.
2. **A character is a grapheme, here as everywhere.** Emerald's strings count, index, and
   search by grapheme (9.1, 9.2). A regex that matched code points would give `.` a
   different idea of "one character" than `count`, and could report a match that splits
   `é` or a family emoji in two. Swift's `Regex` matches by grapheme by default for the same
   reason.
3. **Familiar syntax, honestly refused where unsupported.** The pattern language is the
   common core that JavaScript, Python, Java, Go, and Rust share, so tutorials and existing
   knowledge carry over. Syntax outside it is rejected by name, with the reason and an
   alternative, never silently treated as literal text.
4. **Errors are pedagogy.** A bad pattern names what is wrong and where in the pattern; a
   pattern written as a string literal is checked before the program runs.
5. **Values, not machinery.** A `Regex` is an ordinary value: it prints as its pattern,
   compares by pattern and options, and can be a dictionary key. Compiled programs are a
   runtime cache the program never sees.

## Verified constraints (checked against source, 2026-09-25)

- **Raw strings suit patterns.** Single-quoted strings process no escapes (5.1), so
  `Regex('\d+')` means what it says.
- **The Unicode tables have what grapheme matching needs, except general categories.**
  `src/unicode/tables.zig` (UCD 17.0.0) has grapheme break properties, `White_Space`,
  casing, and NFC data, and `unicode.zig` has `isGraphemeBoundary`, `normalize`, and
  `equal`. It has no `General_Category`, `Alphabetic`, or case folding, which `\w` and
  `ignore_case` need. `tools/unicode/generate.zig` already reads `UnicodeData.txt` and
  `DerivedCoreProperties.txt`; `CaseFolding.txt` and `PropList.txt`'s `Join_Control` are
  new. `unicode.org` is blocked in cloud sessions, but the same files are served from
  `https://raw.githubusercontent.com/unicode-org/unicodetools/main/unicodetools/data/ucd/17.0.0/`.
- **Nested types exist** (14.3), so the match type can be `Regex.Match` rather than a
  top-level `Match` that programs might want for themselves.
- **String semantics to agree with.** `split` keeps empty pieces (`",a,,b,".split(",")` is
  `["", "a", "", "b", ""]`) and refuses an empty separator; searching compares canonically
  and only matches whole graphemes (9.2).
- **Native dispatch evaluates arguments by position** (the Console plan's finding), so
  methods with named or defaulted arguments are written in Emerald in the prelude, over a
  few positional native primitives, as `Console` and the date types are.
- **Startup cost.** Every run type-checks the prelude (handoff rough edge). The engine is
  native Zig; the prelude part stays small.

## Proposed API

All in the `Emerald` namespace. `Regex` is a struct; `Regex.Match` is nested in it.

```emerald
Regex(pattern: String, ignore_case: Bool = false, multiline: Bool = false)
Regex.escape(text: String): String       # a pattern that matches `text` literally

regex.pattern: String
regex.ignore_case: Bool
regex.multiline: Bool
regex.matches?(text: String): Bool             # the whole text
regex.contains_match?(text: String): Bool
regex.find(text: String): Regex.Match?         # the first match
regex.find_all(text: String): List[Regex.Match]
regex.replace(text: String, replacement: String): String       # the first match
regex.replace_all(text: String, replacement: String): String
regex.replace_each(text: String, block: func(Regex.Match): String): String
regex.split(text: String): List[String]

found.text: String
found.start: Int              # grapheme index; text[found.start..<found.end] is found.text
found.end: Int
found.group(number: Int): String      # 0 is the whole match
found.group_maybe(number: Int): String?
found.named(name: String): String
found.named_maybe(name: String): String?
```

- **Options are named arguments,** not inline flags such as `(?i)`: `Regex('hello',
  ignore_case: true)` reads as English, and matches how `Console.style` takes options.
  `multiline` makes `^` and `$` match at the start and end of each line as well.
- **Replacement text is literal.** `replace_all(text, "$1")` inserts a dollar sign and a
  one. Other languages give `$1` or `\1` special meaning in replacements, which surprises
  anyone replacing with a price; computed replacements, including ones that use groups, go
  through `replace_each` and a block, which is ordinary Emerald.
- **`find_all` finds non-overlapping matches from left to right.** After an empty match, the
  search moves on one grapheme, so `Regex('x*').find_all("ab")` finds three empty matches.
  An empty match just where the previous match ended does not count, as in Go and Rust, so
  `Regex('\s*').find_all("a b")` finds an empty match at 0, the space, and an empty match
  at 3, not a fourth one at 2 as Python does. (Settled in slice 3.)
- **`split` keeps empty pieces,** as `String.split` does, and an empty-matching pattern splits
  between every grapheme: an empty match at the very start or end of the text splits nothing
  off, as in Go and JavaScript, so `Regex('').split("abc")` is `["a", "b", "c"]`. A match
  that is not empty does split there: `Regex(',').split(",a")` is `["", "a"]`.
- **A `Regex` is a value.** Two are equal when their patterns and options are; it prints as
  its pattern; it can be a dictionary key or `const`. A `Regex.Match` is a value too, and
  prints as `Regex.Match("42" at 3..<5)`.

## Pattern language

Supported, with the meaning JavaScript, Python, and Rust share:

| Syntax | Meaning |
| --- | --- |
| `a`, `\.`, `\\`, `\n`, `\t`, `\u{1F600}` | Literal characters; a literal compares canonically, as `==` does |
| `.` | Any one grapheme except a line break (`\n`, or `\r\n`, which is one grapheme) |
| `[abc]`, `[a-z]`, `[^0-9]`, `[\w-]` | A set of characters; ranges are by code point |
| `\d` `\D` | ASCII digits 0–9, and not |
| `\w` `\W` | Word characters: letters, marks, decimal digits, and connector punctuation such as `_` (Unicode's definition, UTS #18), and not |
| `\s` `\S` | Unicode white space, and not |
| `^` `$` | Start and end of the text, or of any line with `multiline: true` |
| `\b` `\B` | A word boundary, and not |
| `x*` `x+` `x?` `x{3}` `x{2,}` `x{2,5}` | Repetition, as many as possible |
| `x*?` `x+?` `x??` `x{2,5}?` | Repetition, as few as possible |
| `x\|y` | Either |
| `(x)` `(?<name>x)` `(?:x)` | A numbered group, a named group, and a group that captures nothing |

Decisions within it:

- **`\d` is ASCII only.** A Unicode `\d` also matches Arabic-Indic or Devanagari digits,
  which `to_int` then refuses, so `Regex('\d+')` followed by `to_int()` could fail on text
  that matched. `\w` stays Unicode, since names and words in every script should count.
- **A grapheme belongs to a set by its first code point in NFC.** `[a-z]` does not match
  `é`, whether it is written as one code point or as `e` and a combining accent: the accent
  is part of the character, and a character matches the same way however it is encoded.
  `[é]` matches both forms. (Refined in slice 2: the proposal had used the first code point
  as written, which would have let decomposed `é` match `[a-z]`.)
- **A repetition never takes a round that matches nothing.** `(a|)*` on `"b"` matches the
  empty string with group 1 unset; Python and Perl take one empty round and record it, and
  so report group 1 as `""`. RE2, Go, and Rust behave as Emerald does, and it is what keeps
  every repetition finite.
- **`\B` matches an empty text,** which has no word boundary; Python's `\B` never matches
  there, while Rust's and Go's do.
- **`$` matches only at the very end,** not also before a final newline as Perl and Python
  allow; Go and Rust agree. `multiline` covers line ends.
- **`ignore_case` uses Unicode simple case folding,** so `Regex('straße', ignore_case: true)`
  matches `STRASSE` only where simple folding says so. Full folding, where one character
  becomes two, is deferred.

Refused, each with a specific `RegexError` that says why and what to do instead:
backreferences (`\1`, `\k<name>`), lookahead and lookbehind (`(?=`, `(?!`, `(?<=`, `(?<!`),
atomic groups and possessive repetition, inline flags (`(?i)`: use `ignore_case:`), `\A`,
`\z`, and `\Z` (use `^` and `$`), and Unicode property classes `\p{...}` (a later addition).
A repetition count over 1000, or a pattern that compiles to more than a fixed number of
instructions, is refused as too large rather than allowed to use unbounded memory.

## Errors

- **`RegexError`** extends `RuntimeError`. Its message quotes the pattern, gives the grapheme
  position in the pattern, and names the problem:
  `the pattern "(\d+" at position 0: a "(" here has no matching ")"`, or
  `the pattern "a(?=b)" at position 1: "(?=" here is lookahead, which Emerald's regular
  expressions do not support, so that matching always takes time in proportion to the text`.
- **A pattern known before the program runs is checked then.** When `Regex(...)`'s first
  argument is a string literal, the checker compiles it with the same Zig code and reports
  the error as an ordinary diagnostic, pointing at the exact character inside the literal in
  the source. The LSP then shows it while typing. Patterns built at run time raise
  `RegexError` as above.
- **Groups follow the `to_int` / `to_int_maybe` pattern (9.4).** `found.group(n)` and
  `found.named(name)` return the group's text, and raise `RegexError` when the group took no
  part in the match, as in `(x)?` without an `x`; the `_maybe` forms return `nothing`
  instead. A group the pattern does not have raises for every form, naming the groups it
  does have, since asking for one is always a mistake.

## Implementation approach

- **The engine is Emerald's own, in Zig** (`src/Regex.zig`): a parser to a small syntax tree
  with positions, a compiler to instructions, and a Pike VM (Thompson's NFA simulation with
  capture slots) that runs over the text's graphemes. Leftmost-first semantics, as
  backtracking engines have, so results match what users expect from other languages.
  Wrapping PCRE2, as 15.4 had anticipated, was weighed and rejected: it backtracks, it
  counts code points rather than graphemes, and it would add Emerald's first C dependency
  to every platform's build. Zig's standard library has no regex engine.
- **Text is matched as graphemes.** The subject is segmented once with the existing grapheme
  rules; each grapheme keeps its byte range for building results, and literal comparison
  uses the existing canonical equality. Positions are grapheme indices, consistent with
  indexing and slicing.
- **Compiled programs are cached** per interpreter, keyed by pattern and options, so a
  `Regex` built in a loop is compiled once.
- **The prelude part is thin:** the `Regex` struct holding its pattern and options, the named
  and defaulted signatures, and `replace_each`'s block call, over a few positional natives
  (`_find(pattern, options, text, start)` and similar).
- **Unicode data:** `tools/unicode/generate.zig` gains `Alphabetic`, the `Mark`,
  `Decimal_Number`, and `Connector_Punctuation` general categories, `Join_Control`, and
  simple case folding, from the same UCD 17.0.0 release.

## Slices

Each slice is runnable and committed on its own, with AGENTS.md's validation (Debug and
ReleaseSafe `zig build test`, `zig build`, `zig fmt --check`, the doc-example check,
`git diff --check`) and rewrite-context text written in the same change as the code.

1. **Unicode data.** Regenerate `src/unicode/tables.zig` with the new properties, keeping
   version 17.0.0; add lookup functions and unit tests; run the Unicode conformance tests.
   Done: `word` and `simple_fold` tables, `unicode.isWordCharacter` and
   `unicode.simpleFold`. Both tables match an independent Python parse of the UCD files
   (149,366 word characters, 1,512 foldings), and regenerating from the GitHub mirror
   first reproduced the existing tables byte for byte.
2. **The engine, without Emerald.** `src/Regex.zig`: parsing with positioned errors for
   every refused feature, compiling, the Pike VM over graphemes, captures, both options, and
   the size limits. Zig unit tests, plus a differential check against Python's `re` on
   generated ASCII patterns and texts (a local tool, where the two engines' semantics
   agree), and a timing test that `(a+)+$` against a long run of `a`s stays linear.
   Done: `src/Regex.zig` with unit tests, and `tools/regex-differential.py` with
   `tools/regex_probe.zig`. Across 30,000 generated cases (seeds 1–3) its first match and
   every group agree with Python's `re`; the generator leaves out the two deliberate
   differences above (empty rounds, and `\B` on an empty text), which the first run found.
   `(a+)+$` and three other patterns that take backtracking engines exponential time finish
   at once on 20,000 characters.
3. **The Emerald API.** `Regex`, `Regex.Match`, `RegexError`, and every method above except
   groups; conformance cases for matching, finding, replacing, splitting, options, empty
   matches, graphemes (`é` in both forms, emoji, `\r\n`), and runtime errors.
   Done: the prelude's `Regex` and `Regex.Match` over six positional natives
   (`_problem`, `_whole?`, `_find`, `_replace`, `_split`, `_splice`, plus `Regex.escape`) in
   `Interpreter.callRegex`, which build `Regex.Match` values directly so their private group
   fields need no public constructor. `Regex.Matcher` keeps the engine's working space
   between the runs of one search. Compiled programs are cached per execution, keyed by
   options and pattern, up to 256 of them; past that a pattern is compiled for each call.
   Measured on a 1.2 MB text (ReleaseSafe): `find_all('\w+')`, 240,000 matches, 0.7 s, most
   of it building match values; `replace_all('\d+')` 0.3 s; `split('\s+')` 0.5 s; the
   engine alone finds the 240,000 matches in 0.15 s after 0.09 s of grapheme segmentation.
   A ReleaseSafe `print(1)` starts about 0.3 ms later than before.
4. **Groups.** `group`, `group_maybe`, `named`, `named_maybe`, and groups inside
   `replace_each`; conformance for optional groups, nested groups, and names.
   Done: the four methods are Emerald in `Regex.Match`, over the private `_spans`, `_texts`,
   `_names`, and `_pattern` fields `_find` fills; a name of `""` never finds the unnamed
   groups' placeholder. Writing the conformance case exposed a formatter bug, fixed in the
   same change: `emerald format` printed `a?.b` as `a.b`, changing what a program means.
5. **Checking literal patterns.** The checker reports a bad literal pattern at its source
   position; diagnostics cases, and LSP behavior checked over JSON-RPC.
   Done: `Checker.checkLiteralPattern`, run after a `Regex(...)` call's arguments are
   checked, compiles a literal first argument (positional or `pattern:`) with
   `Regex.compile`. The diagnostic points at the pattern's character when the literal's
   source text is exactly its value (no escapes, not triple-quoted), and otherwise at the
   whole literal with the position in the message. Checked over JSON-RPC: `emerald lsp`
   publishes the diagnostic with UTF-16 columns (after an emoji too) and clears it once the
   pattern is fixed. Two conformance cases that had written bad literal patterns to test
   the runtime error now build them as the program runs. Building a `Regex.Match` directly
   now says where one comes from, instead of suggesting a default for its private field.
6. **Documentation and integration.** `docs/library/regex.md`, an inventory row,
   `examples/regex.em` with the programs above, rewrite-context 15.4 rewritten with the
   settled behavior and decision-table rows in 22, a fuzz template, and 15.7 updated.

   Done: [`docs/library/regex.md`](library/regex.md), with every intentional difference from
   other engines and its reason; an inventory row; a pointer from `String`'s search methods;
   [`examples/regex.em`](../examples/regex.em) with the programs above (reading a list rather
   than `input`, so the doc check can run it); rewrite-context 15.4 rewritten with the
   settled behavior, five decision rows in 22, and 15.7 marking regular expressions done; and
   a fuzz template that builds, searches, replaces, splits, and reads groups.

## Out of scope for this milestone

Backreferences and lookaround (ruled out by principle 1), `\p{...}` properties, full case
folding, inline flags, verbose/commented patterns, matching over byte strings or `Bytes`,
`String` methods that take a `Regex` (15.4 keeps literal methods literal), and a regex
literal syntax (22 already rules one out). Each can be revisited with a real program that
needs it (24).

## Risks

- **Grapheme matching costs a segmentation pass.** Linear, and done once per call: about
  0.09 s for 1.2 MB, measured in slice 3 (above), so segmentation is not cached per text.
- **Case-insensitive matching over graphemes** has edge cases where folding changes a
  grapheme's length. Simple folding per code point, applied to both sides, keeps it
  well-defined; the differential test covers the ASCII core.
- **Divergence from other engines** users compare against. Every intentional difference
  (`\d`, `$`, literal replacements, graphemes) is listed on the library page with the reason.
