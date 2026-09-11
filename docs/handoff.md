# Current handoff

Updated: 2026-09-10. Prepared by Claude after the source manager and diagnostics slice.

## Current milestone

Slices 1 and 2 of section 20 are complete: the build layout exists, and source loading and
diagnostics work end to end. There is no lexer, parser, checker, or interpreter yet.

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
- `src/emerald.zig` is the library root and holds `check`, which currently reports only
  encoding problems because no later stage exists.
- `src/main.zig` implements `emerald check <file>` with the section 18.1 exit codes.

## Next concrete step

Slice 3 of section 20: the lexer. Identifiers, integers, strings, comments, newline, and
EOF, each carrying a `Source.Span`. Two rules already settled deserve tests from the start:
the newline-continuation token list in 3.1, and the `T?` split described in 4.2, whose
conformance case is

```emerald
func valid?(): Bool? {
    return nothing
}
```

The first runnable Emerald milestone remains integer arithmetic, `var`/`const`, name and
type checking, and `print`, as in `examples/arithmetic.em`.

## Validation and blockers

- `zig build test` passes: 14 unit tests plus 3 command-line contract tests asserting the
  section 18.1 exit codes against the real binary. The command-line tests were confirmed to
  fail when the example is broken, so they are not vacuous.
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

### Known rough edges

- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.

## Pending changes

None. The working tree is clean; verify against Git before continuing.
