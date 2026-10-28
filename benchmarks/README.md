# Benchmarks

Roadmap item 7: a dozen programs, each exercising one part of the interpreter, with recorded
timings. They are the baseline that shows whether the compiler is faster, and they catch the
interpreter getting slower.

| Program | Exercises |
| --- | --- |
| `fib` | function calls and whole-number arithmetic |
| `sieve` | loops and list indexing |
| `nbody` | structs and `Float` arithmetic |
| `sorting` | `sort` and `sort_by` on long lists |
| `words` | text, `words()`, and dictionary counting |
| `strings` | interpolation, characters, and `join` |
| `shapes` | classes and methods chosen at run time |
| `pipeline` | blocks: `map`, `filter`, `reduce` |
| `generics` | a generic class used heavily |
| `json` | encoding and decoding records |
| `regex` | matching many lines |
| `channels` | tasks passing values through a channel |
| `life` | a game-like frame loop on a grid of lists |

Each prints a short answer, checked against its `.expected` file on every run, so a change that
is fast because it is wrong never counts. Each takes roughly half a second in a ReleaseSafe
build. `zig build test` checks that they stay formatted, but does not run or time them: CI
asserts work, never elapsed time.

```bash
zig build -Doptimize=ReleaseSafe --prefix /tmp/before    # on the commit to compare against
zig build -Doptimize=ReleaseSafe --prefix /tmp/after     # on your change
python3 tools/benchmark.py /tmp/before/bin/emerald /tmp/after/bin/emerald
```

Two binaries' runs alternate, so drift on a busy machine affects both alike; the last column is
the second's median as a share of the first's. `--only fib` runs one program, `--runs N` changes
the five runs, and `--record` rewrites [`baseline.md`](baseline.md) from one binary. Record only
on a quiet machine, and note the result in `docs/journal.md`.
