# Current handoff

Updated: 2026-09-10. Prepared by Claude after the lexer slice.

## Current milestone

Slices 1 through 3 of section 20 are complete: the build layout exists, source loading and
diagnostics work end to end, and the lexer produces tokens with spans. There is no parser,
checker, or interpreter yet.

## Completed foundation

- The .NET prototype is archived under `legacy/dotnet-v0/`, tagged `dotnet-v0-final`.
- [rewrite-context.md](rewrite-context.md) is the canonical language and architecture
  baseline. The implementation host is Zig.
- Zig `0.16.0` is pinned through [mise.toml](../mise.toml) and
  [toolchain/zig-version.txt](../toolchain/zig-version.txt), verified by
  [tools/check-toolchain.sh](../tools/check-toolchain.sh).
- Shared agent instructions are committed in `AGENTS.md` and `CLAUDE.md` (`f3c38cb`).

## Pre-implementation decision pass

The user asked for a judgment call on the remaining open design questions, prioritizing
beginner friendliness, sound design, and expressive syntax. Seven decisions were settled
and recorded in the rewrite context, each in its normative section plus a summary table in
section 22 under "Pre-implementation decision pass":

- `Int` is 64-bit signed with checked overflow; `Float` is IEEE-754 binary64 (4.2, 5.3).
- The optional type keeps the postfix `T?` (4.2). Its clash with `?`-suffixed identifiers
  is lexical: the lexer emits `Int?` as one identifier token and the parser splits the
  trailing `?` in type position. 4.2 records the rule and a required conformance test.
- Optionals never nest; lossy operations get documented unambiguous companions (4.5, 8.3,
  8.6).
- Overloading is deferred; named factory functions replace overloaded constructors, and
  mixed-type operators are deferred with it (7.3, 10.2, 11.5, 21).
- Type declaration bodies are braced only; the block-free to-EOF form is removed (10.6,
  14.3).
- Struct method capture keeps its value semantics and gains a teaching equivalence (7.5).
- String normalization happens at comparison; construction preserves the original bytes
  (9.2).

Section 24 no longer lists the optional spelling as an open roadmap item.

## Implemented so far

- `build.zig` provides `zig build`, `zig build test`, and `zig build run`.
- `src/Source.zig` is the immutable source-file record: UTF-8 with byte-order mark removal,
  LF and CRLF line handling, byte-offset spans, and one-based line and scalar-column
  mapping. It also locates the first invalid UTF-8 sequence and its span.
- `src/Diagnostic.zig` renders the canonical four-part shape from section 17.1, with the
  underline measured in scalars so it aligns past multi-byte characters.
- `src/Token.zig` holds the token kinds, the keyword table, and `canEndExpression`, which
  is the continuation-token list section 3.1 refers to. The switch is exhaustive, so a new
  kind cannot be added without classifying it.
- `src/Lexer.zig` produces tokens with spans: names, keywords, numbers, the three string
  forms, comments, operators, statement-terminating newlines, and EOF.
- `src/emerald.zig` is the library root and holds `check`, which reports encoding and
  lexical problems. It returns a `Report` of every diagnostic rather than only the first.
- `src/main.zig` implements `emerald check <file>` with the section 18.1 exit codes.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `valid/` must produce no diagnostics; cases in `diagnostics/` must match their `.expected`
  file exactly. See [conformance/README.md](../conformance/README.md) for how to add one.

### Lexical decisions worth knowing

- A newline is emitted only when the previous token can end an expression and no `(` or `[`
  is open. Braces deliberately do not open a group, so statements inside a block still end
  at a newline. Because `.newline` itself cannot end an expression, runs of blank lines
  collapse with no special handling.
- Section 3.3 lets a name end in `?` or `!`, which collides with `?.` and `!=`. A trailing
  marker joins the name unless the next character forms the operator, so `user?.name` and
  `a!=b` lex correctly while `empty?()` and `sort!()` keep their markers. The section 4.2
  conformance case `func valid?(): Bool?` is covered by a test.
- A `.` is a decimal point only when a digit follows, which is what keeps `5.times` a method
  call and `1..5` a range rather than malformed numbers.
- Documentation comments are tokens because the parser needs them. Line and block comments
  are skipped, which the formatter slice will have to revisit.

## Next concrete step

Slice 4 of section 20: parse and evaluate integer arithmetic with precedence. Section 5.3
fixes the operator set and the two rules most easily got wrong — `**` binds tighter than
unary minus and is right-associative, so `-2 ** 2` is `-(2 ** 2)` and `2 ** 3 ** 2` is
`2 ** (3 ** 2)`. Overflow is checked against the 64-bit range settled in 4.2.

The first runnable Emerald milestone remains integer arithmetic, `var`/`const`, name and
type checking, and `print`, as in `examples/arithmetic.em`.

## Validation and blockers

- `zig build test` passes: 54 unit tests, 13 conformance cases, and 5 command-line contract
  tests asserting the section 18.1 exit codes against the real binary. Both the conformance
  suite and the command-line tests were confirmed to fail when a case is broken, so they are
  not vacuous.
- Writing the conformance suite immediately found a real defect. The standard streams were
  opened in positional mode, which starts at offset zero, so with output redirected to a
  file each diagnostic overwrote the one before it and only the last survived. Standard
  streams now use `writerStreaming`. Note that the defect is invisible when output goes to a
  terminal or a pipe, which is why the command-line contract tests did not catch it; the
  guard against a regression is the comment in `writeAll` plus the two-diagnostic
  command-line case, which at least proves both diagnostics are emitted.
- `bash tools/check-toolchain.sh` passes.
- Verified against the pinned standard library: `std.unicode` provides UTF-8/UTF-16
  encoding, decoding, validation, and code-point counting only — no grapheme segmentation
  and no normalization. Emerald must vendor UAX #29 and UAX #15 tables for grapheme
  indexing (9.1) and normalized equality (9.2). This is recorded in 19.1 and should be
  planned into the string slice, not discovered during it. `std.fmt` does provide
  shortest-round-trip float formatting, satisfying 9.4.
- Zig 0.16 API notes worth not rediscovering: `zig env` emits ZON rather than JSON;
  `std.fs` is deprecated in favor of `std.Io.Dir`; `std.process.argsAlloc` is gone and
  `main` instead takes a `std.process.Init` supplying the allocator, `Io`, and arguments;
  `addExecutable` and `addTest` take a `root_module` built by `b.createModule`.

### Open question raised by writing the conformance cases

Section 3.1 decides continuation from the preceding tokens only, explicitly "rather than
indentation or the next line". That rules out the leading-dot method chain that Kotlin,
Swift, and C# all allow:

```emerald
var count = numbers
    .filter { number => number > 0 }
    .count
```

As written, the newline after `numbers` ends the statement, because an identifier can end an
expression. This matters more for Emerald than for most languages, because section 5.4 makes
method chaining the pipeline notation and declines a separate pipeline operator, so long
chains are the idiomatic style and will want to wrap. Supporting it means letting a leading
`.` on the next line continue the previous statement, which is a deliberate exception to the
"preceding tokens only" rule rather than an oversight in it. A conformance case was written
using this form and then removed, since the rule as written rejects it.

This needs a decision before the parser slice fixes the behavior by accident.

### Known rough edges

- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.
- String interpolation is not scanned yet, so a `"` inside `#{...}` ends the string early.
  Strings are lexed as whole tokens and left uncooked; escape processing, indentation
  stripping for triple-quoted strings, and interpolation all belong to one later slice.
- Identifier characters are currently any ASCII letter, digit, underscore, or any non-ASCII
  byte. Section 3.3 specifies Unicode XID classes with NFC normalization and no emoji, which
  needs the tables section 19.1 schedules for the string slice. Accepting too much now and
  tightening later keeps valid programs valid.
- A multi-line block comment joins the lines around it rather than terminating a statement,
  matching how C-family languages treat their block comments.

## Pending changes

None. The working tree is clean; verify against Git before continuing.
