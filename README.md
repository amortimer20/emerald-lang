# Emerald

Emerald is an experimental, statically typed programming language designed to be
approachable for beginners and expressive enough to remain enjoyable as programs grow.

Emerald is being reimplemented from scratch in Zig. The current language baseline,
implementation architecture, staged plan, and evidence-driven roadmap live in
[`docs/rewrite-context.md`](docs/rewrite-context.md).

The in-repository documentation source is being organized under
[`docs/language/`](docs/language/) and [`docs/library/`](docs/library/). It is the
canonical language and standard-library reference; a future documentation site may present
that source without becoming a second specification.

## Rewrite status

Emerald runs and type-checks. The whole frontend of section 19.2 exists — source manager,
lexer, parser, name resolver, type checker, interpreter — so `emerald run` executes a
program, `emerald check` reports its problems without running it, and `emerald test` runs
its top-level `@test` functions.

Named bindings, type annotations, assignment, conditionals, comparison, arithmetic,
functions, loops, collections, strings, projects, and blocks work. Structs, classes,
inheritance, traits, enums, typed errors, assertions, and tests work too. The first program
of the language guide runs:

```emerald
var name = input("What is your name? ")
print("Hello, #{name}!")
```

Strings are Unicode-aware: a character is what a reader sees as one, canonically
equivalent strings are equal, and case mapping is Unicode's, from tables generated from
Unicode 17.0.0. Definite assignment is proved through control flow, including loops; lists
are values, copied on write. An unhandled error inside a function reports the calls that
led to it. Functions are values: a block can be written inline, passed to `each` or `map`,
or kept in a variable, and it captures the variables around it rather than copies of them.
A value that may be absent is marked `?`, and the language makes you say what happens when
it is missing — by checking it against `nothing`, which then lets you use it as an ordinary
value, or by giving it a fallback. Memory is managed for you, by reference counting with a
mark-and-sweep collector behind it for the cycles counting cannot reach. Errors are typed
values handled with `try` and `catch`; `finally` performs cleanup on every exit path.

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

```emerald
func counter_from(start: Int): func(): Int {
    var next = start
    return { =>
        next += 1
        return next - 1
    }
}

const ticket = counter_from(1)
print(ticket(), ticket(), ticket())
print([1, 2, 3].map { number => number * number })
```

```emerald
const entries = ["12", "seven", "30"]
print(entries.map { entry => entry.to_int_maybe().or(0) })

const first_long = entries.find { entry => entry.count > 2 }
if first_long != nothing {
    print(first_long.upper())
}
```

The current toolchain is Zig `0.16.0`, selected through [`mise.toml`](mise.toml). Verify
the exact version and compile and run the toolchain probe with:

```bash
bash tools/check-toolchain.sh
```

## Installing Emerald with Mise

Emerald is set up for release-based installation. GitHub Releases are the source of truth for
platform binaries, and Mise can install the correct asset directly from the GitHub repository.

The expected release layout is:

- `emerald-linux-x86_64.tar.gz`
- `emerald-macos-arm64.tar.gz`
- `emerald-windows-x86_64.zip`

and each release also includes a `SHA256SUMS` file for verification.

The intended user flow is:

```bash
mise use -g "github:amortimer20/emerald-lang@latest"
```

Or for a specific version:

```bash
mise use -g "github:amortimer20/emerald-lang@v0.3.0"
```

If `@latest` fails to resolve (older Mise versions can mishandle GitHub's release
metadata), pin an explicit tag as shown above, or run `mise self-update` first.

Build, test, and run:

```bash
zig build                              # build zig-out/bin/emerald
zig build test                         # unit tests and command-line contract tests
zig build run -- --version             # prints Emerald 0.4.0-dev
zig build run -- run examples/greeter.em
zig build run -- test path/to/project
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
  Heap.zig           list and string storage, reference counts, and copy-on-write
  Interpreter.zig    evaluates a syntax tree
  strings.zig        the string operations of section 9
  unicode.zig        grapheme clusters, normalization, case mapping, identifiers
  unicode/tables.zig generated Unicode data; see tools/unicode
  Project.zig        finds and loads the files a program is made of
  conformance.zig    runs the Emerald conformance suite
conformance/         Emerald cases and their expected results
examples/            Emerald programs used as fixtures and targets
toolchain/           pinned Zig version and compiled probes
tools/               repository check scripts and the Unicode table generator
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

## Implementation

The Zig rewrite is the sole maintained implementation. Historical design decisions are
captured in [`docs/rewrite-context.md`](docs/rewrite-context.md).
