# Current handoff

Updated: 2026-09-10. Prepared by Claude after the pre-implementation design pass.

## Current milestone

Design is closed for the first implementation slices. The Zig interpreter has not been
started: there is no root `build.zig`, lexer, parser, checker, or interpreter yet.

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

## Next concrete step

Establish the minimal Zig build layout and source diagnostics, which is slice 1–2 of
section 20. Inspect Zig 0.16.0's local build APIs before writing `build.zig`. Add
`zig build` and `zig build test`, then source loading and source spans with one useful
diagnostic.

The first runnable Emerald milestone is integer arithmetic, `var`/`const`, name and type
checking, and `print`:

```emerald
var score = 2 + 3 * 4
print(score) # 14
```

## Validation and blockers

- The Zig smoke probe previously compiled and ran, printing `0.16.0` and
  `Zig toolchain ready.`
- The design pass is documentation only. `git diff --check` is clean.
- Verified against the pinned standard library: `std.unicode` provides UTF-8/UTF-16
  encoding, decoding, validation, and code-point counting only — no grapheme segmentation
  and no normalization. Emerald must vendor UAX #29 and UAX #15 tables for grapheme
  indexing (9.1) and normalized equality (9.2). This is recorded in 19.1 and should be
  planned into the string slice, not discovered during it. `std.fmt` does provide
  shortest-round-trip float formatting, satisfying 9.4.
- Note that `zig env` emits ZON, not JSON, in 0.16.0; parse it accordingly in tooling.
- No known blocker to the initial Zig slice.

## Pending changes

None. The decision pass and this handoff are committed. The working tree is clean; verify
against Git before continuing.
