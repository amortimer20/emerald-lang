<p align="center">
  <img src="assets/emerald.svg" width="96" alt="Emerald logo">
</p>

<h1 align="center">Emerald</h1>

<p align="center">A statically typed programming language made to be approachable for beginners and enjoyable as programs grow.</p>

```emerald
func greet(name: String): String {
    return "Hello, #{name}!"
}

print(greet("Ada"))
```

Emerald combines type inference and explicit types, optionals, Unicode-aware strings,
collections, structs, classes, traits, enums, typed errors, and a small standard library.
It also includes a formatter, REPL, language server, and built-in test command.

Emerald is in active `0.x` development. It is ready to explore, but language and library
details may change between releases.

## Install

The easiest way to install a released binary is [Mise](https://mise.jdx.dev/):

```bash
mise use -g "github:amortimer20/emerald-lang@latest"
emerald --version
```

Released packages are available for Linux x86_64, macOS ARM64, and Windows x86_64. See the
[installation guide](docs/mise-install.md) for pinned-version installation and troubleshooting.

## Try it

Save the example above as `hello.em`, then run:

```bash
emerald run hello.em
```

The commands you will use most often are:

```bash
emerald check hello.em          # check without running
emerald run hello.em            # check, then run
emerald test hello.em           # run @test functions
emerald format --check hello.em # see whether formatting would change it
emerald help                    # discover commands and their usage
```

## Build from source

Emerald uses the pinned Zig version in [`mise.toml`](mise.toml).

```bash
git clone https://github.com/amortimer20/emerald-lang.git
cd emerald-lang
bash tools/check-toolchain.sh
zig build
zig build run -- run examples/greeter.em
```

Run the full test suite with `zig build test`.

## Learn Emerald

- [Language guide](docs/language/README.md) — learn syntax, types, objects, errors, tests, and projects.
- [Standard-library reference](docs/library/README.md) — look up built-in types and APIs.
- [Examples](examples/) — small runnable programs, including a ledger and a binary hex-dump tool.
- [Diagnostics guide](docs/language/diagnostics.md) — understand compiler messages and `emerald explain`.

## Project information

The [language design baseline](docs/rewrite-context.md) records Emerald's settled behavior and
deferred ideas. The [engineering journal](docs/journal.md) records completed implementation
work and lessons learned. Emerald is released under the [MIT License](LICENSE).
