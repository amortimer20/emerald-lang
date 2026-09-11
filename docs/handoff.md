# Current handoff

Updated: 2026-09-10. Prepared by Claude after the statement slice.

## Current milestone

Slices 1 through 5 of section 20 are complete, and the first milestone program from
section 20 runs. `emerald run` executes a program and `emerald check` analyses one without
running it. Named bindings, assignment, conditionals, comparison, and arithmetic all work.

There is no type checking yet, so a condition that is not a `Bool`, and arithmetic on
mismatched kinds, are runtime errors rather than something `check` catches.

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
- `src/Ast.zig` is the syntax tree, free of runtime values so a future backend consumes the
  same tree the interpreter does.
- `src/Parser.zig` parses statements and expressions with section 5.3's precedence.
- `src/Resolver.zig` is name resolution: scopes, declarations, and the section 6.1 rules.
  These belong here rather than in the interpreter because they are properties of the text
  rather than of a run. A name declared inside `if false { }` still shadows.
- `src/Value.zig` holds `Nothing`, `Bool`, `Int`, and `Float`, implements section 9.4's
  display rules, and orders values.
- `src/Interpreter.zig` evaluates, applying section 5.3's result types and failure modes.
- `src/emerald.zig` is the library root. `check` and `run` share one pipeline that stops at
  the first stage to report anything, which is section 17.2's rule against cascades.
- `src/main.zig` implements `emerald check` and `emerald run` with the section 18.1 exit
  codes, including `2` for an uncaught runtime error.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `lexical/` must tokenize cleanly, `diagnostics/` must match their `.expected` exactly,
  `run/` must print theirs, and `runtime-errors/` must fail with theirs. See
  [conformance/README.md](../conformance/README.md) for how to add one.

### Statement decisions worth knowing

- Name resolution is its own pass, so shadowing, undefined names, and assigning to a `const`
  are reported by `check` rather than only when a line happens to run.
- Section 3.4's brace style puts `else` on its own line, so a newline always sits between
  `}` and `else`. That newline terminates a statement everywhere else, so the parser looks
  past it only once an `else` is known to follow.
- The prelude is a scope of its own, below the program's. That is what lets a program
  declare a name matching a prelude function without it counting as the shadowing section
  6.1 forbids, matching the rule that a local may reuse a module-level name.
- A comparison chain is one node holding all its operands. That is what makes "evaluate the
  middle expression once" and "short-circuit as if joined by `and`" fall out naturally
  rather than being reconstructed by the evaluator.
- Section 4.4's mixed comparison rule rules out the obvious implementation: widening the
  `Int` to a `Float` first would make `9007199254740993 == 9007199254740992.0` true, which
  is the accidental equality the rule exists to prevent. `Value.order` splits the float
  instead.
- `Nothing` arrived with this slice rather than later, because `print` had been returning a
  placeholder `Int` that `var x = print(1)` would have exposed as a lie.

### Expression decisions worth knowing

- The right operand of `**` is parsed as a unary expression rather than as another power.
  That one rule gives the operator its right associativity, lets `2 ** -3` parse, and still
  leaves `-2 ** 2` meaning `-(2 ** 2)` because unary sits above it.
- Section 9.4's float display is written out in `Value.zig` rather than inherited. The host
  disagrees on every interesting case: it renders `2.0` as `2`, `-0.0` as `-0`, `1e16` in
  fixed form, and the special values as `inf` and `nan`.
- Zig's `@divFloor` and `@mod` were verified by probe to match section 5.3 exactly,
  including negative divisors and the law `a == (a // b) * b + (a % b)`.
- Section 5.2's rule that a standalone pure expression is an error is enforced in the
  parser, which is why a program is currently a sequence of calls.

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

Slice 6 of section 20: the static checker. Inferred locals, type annotations, definite
assignment, and operand errors reported before execution rather than during it. Everything
currently deferred to runtime moves here: a condition that is not a `Bool`, arithmetic on
mismatched kinds, and comparing values that have no ordering.

Two pieces of groundwork are already in place. `Resolver.zig` has the scope structure a type
environment needs, and `parseDeclaration` currently rejects a `:` annotation with a
"not available yet" message that the checker slice should replace with real parsing.

Section 4.1 is the specification: every expression has a static type before execution, a
local is inferred from its initializer, an uninitialized variable needs an explicit type,
and definite assignment is proved through control flow rather than by inserting a default.

Still open alongside it: the leading-dot question below, and the deferred conditional forms
(`unless`, the modifier guards, and the `if ... then ... else` expression from section 6.2).

## Validation and blockers

- `zig build test` passes: 103 unit tests, 29 conformance cases, and 7 command-line contract
  tests asserting the section 18.1 exit codes against the real binary. Every case kind was
  confirmed to fail when a case is broken, so none of them are vacuous.
- Writing this slice found a leak worth remembering. Returning a struct that owns an
  `ArenaAllocator` by value copies the arena, and the copy snapshots the list of blocks it
  owns. Allocating into the arena inside the same struct literal that copies it therefore
  strands that allocation in the dead local. Finish every allocation before constructing
  the result; `analyze` and `Parser.parse` both do this deliberately.
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

### Deferred within this slice

- Section 6.2's `unless` block form, the one-line modifier guards, and the
  `if ... then ... else` expression. The `unless not condition` style diagnostic also needs
  a severity on `Diagnostic`, which does not exist yet.
- Type annotations on declarations. `parseDeclaration` rejects a `:` with a clear
  "not available yet" message rather than parsing and ignoring it.
- String literals in expressions. The lexer produces the tokens, but nothing consumes them,
  so `conformance/lexical/strings.em` has not graduated.

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
