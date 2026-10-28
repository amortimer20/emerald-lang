# Benchmark baseline

Written by `python3 tools/benchmark.py --record`. Each time is the median wall time of
5 runs of `emerald run`, startup included, with a ReleaseSafe build.

- Recorded: 2026-10-28
- Emerald: Emerald 0.7.0-dev (commit `1afc106`)
- Machine: Darwin 27.0.0, arm64, Apple A18 Pro

Compare a change against a build of this commit with two binaries, not against these
numbers: another machine, or a busy hour, moves every time.

| Program | Median |
| --- | --- |
| `channels` | 0.319s |
| `fib` | 0.309s |
| `generics` | 0.558s |
| `json` | 0.452s |
| `life` | 0.623s |
| `nbody` | 0.468s |
| `pipeline` | 0.589s |
| `regex` | 0.312s |
| `shapes` | 0.330s |
| `sieve` | 0.406s |
| `sorting` | 0.392s |
| `strings` | 0.542s |
| `words` | 0.410s |
