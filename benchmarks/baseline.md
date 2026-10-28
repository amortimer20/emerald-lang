# Benchmark baseline

Written by `python3 tools/benchmark.py --record`. Each time is the median wall time of
5 runs of `emerald run`, startup included, with a ReleaseSafe build.

- Recorded: 2026-10-28
- Emerald: Emerald 0.7.0-dev (commit `4d7a5a3`)
- Machine: Darwin 27.0.0, arm64, Apple A18 Pro

Compare a change against a build of this commit with two binaries, not against these
numbers: another machine, or a busy hour, moves every time.

| Program | Median |
| --- | --- |
| `channels` | 0.317s |
| `fib` | 0.309s |
| `generics` | 0.557s |
| `json` | 0.451s |
| `life` | 0.617s |
| `nbody` | 0.470s |
| `pipeline` | 0.589s |
| `regex` | 0.313s |
| `shapes` | 0.329s |
| `sieve` | 0.402s |
| `sorting` | 0.383s |
| `strings` | 0.533s |
| `words` | 0.405s |
