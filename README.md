# Emerald

Emerald is an experimental, statically typed programming language designed to be
approachable for beginners and expressive enough to remain enjoyable as programs grow.

Emerald is being reimplemented from scratch in Zig. The current language baseline,
implementation architecture, staged plan, and evidence-driven roadmap live in
[`docs/rewrite-context.md`](docs/rewrite-context.md).

## Rewrite status

Emerald runs and type-checks. The whole frontend of section 19.2 exists — source manager,
lexer, parser, name resolver, type checker, interpreter — so `emerald run` executes a
program and `emerald check` reports its problems without running it.

Named bindings, type annotations, assignment, conditionals, comparison, arithmetic,
functions, and loops work. Definite assignment is proved through control flow, including
loops, and an unhandled error inside a function reports the calls that led to it. Strings
and collections arrive with later slices.

```emerald
func collatz_steps(start: Int): Int {
    var number = start
    var steps = 0
    while number != 1 {
        if number % 2 == 0 {
            number = number // 2
        }
        else {
            number = 3 * number + 1
        }
        steps += 1
    }
    return steps
}

for start in 1..5 {
    print(start, collatz_steps(start))
}
```

The current toolchain is Zig `0.16.0`, selected through [`mise.toml`](mise.toml). Verify
the exact version and compile and run the toolchain probe with:

```bash
bash tools/check-toolchain.sh
```

Build, test, and run:

```bash
zig build                              # build zig-out/bin/emerald
zig build test                         # unit tests and command-line contract tests
zig build run -- run examples/loops.em
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
  Ast.zig            the syntax tree
  Parser.zig         tokens to a syntax tree
  Resolver.zig       scopes, declarations, and assignment rules
  Type.zig           static types and their compatibility
  Checker.zig        type checking and definite assignment
  Value.zig          runtime values and how they display
  Interpreter.zig    evaluates a syntax tree
  conformance.zig    runs the Emerald conformance suite
conformance/         Emerald cases and their expected results
examples/            Emerald programs used as fixtures and targets
toolchain/           pinned Zig version and compiled probes
tools/               repository check scripts
```

Language behavior is specified by [`conformance/`](conformance/), whose cases are written
in Emerald rather than Zig so that a future backend must pass the same files unchanged.

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
