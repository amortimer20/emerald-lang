# Emerald

Emerald is an experimental, statically typed programming language designed to be
approachable for beginners and expressive enough to remain enjoyable as programs grow.

Emerald is being reimplemented from scratch in Zig. The current language baseline,
implementation architecture, staged plan, and evidence-driven roadmap live in
[`docs/rewrite-context.md`](docs/rewrite-context.md).

## Rewrite status

The source manager, diagnostics, and lexer are implemented. There is no parser, checker, or
interpreter yet, so `emerald check` currently verifies that a file is well-formed UTF-8 and
that it tokenizes, reporting lexical problems such as unsupported number bases, malformed
literals, unterminated strings, and unclosed block comments.

The current toolchain is Zig `0.16.0`, selected through [`mise.toml`](mise.toml). Verify
the exact version and compile and run the toolchain probe with:

```bash
bash tools/check-toolchain.sh
```

Build, test, and run:

```bash
zig build                              # build zig-out/bin/emerald
zig build test                         # unit tests and command-line contract tests
zig build run -- check examples/arithmetic.em
```

### Layout

```text
build.zig            build, test, and run steps
src/
  main.zig           the emerald command-line entry point
  emerald.zig        frontend library root
  Source.zig         immutable source files, spans, and line/column mapping
  Diagnostic.zig     one reported problem and its canonical rendering
  Token.zig          token kinds, keywords, and the continuation-token list
  Lexer.zig          source text to tokens
examples/            Emerald programs used as fixtures and targets
toolchain/           pinned Zig version and compiled probes
tools/               repository check scripts
```

Language behavior should follow the rewrite context and its conformance tests rather than
behavior inherited from the implementation host.

## Working with coding agents

Codex and Claude share [AGENTS.md](AGENTS.md) for working rules and
[docs/handoff.md](docs/handoff.md) for the current milestone, validation, and next step.
[CLAUDE.md](CLAUDE.md) directs Claude to the same shared context. The rewrite context
remains the authoritative language design.

## Historical .NET prototype

The original C#/.NET implementation is preserved in
[`legacy/dotnet-v0/`](legacy/dotnet-v0/). It remains useful as design history and as a
source of examples, diagnostics, and tests worth reconsidering. It is not the specification
for the rewrite and is no longer maintained.

The last committed state before the reorganization is tagged `dotnet-v0-final`.
