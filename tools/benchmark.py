#!/usr/bin/env python3
"""Runs the benchmark suite in benchmarks/ and reports how long each program takes.

Each program in benchmarks/ exercises one part of the interpreter (calls,
loops and indexing, structs, sorting, dictionaries, strings, classes,
blocks, generics, JSON, regular expressions, tasks, and a game-like frame
loop) and prints a short answer. A run counts only when its output matches
the program's .expected file beside it, so a change that is fast because it
is wrong never looks like a win.

Absolute times drift with whatever else the machine is doing, so compare a
change by giving two binaries: their runs alternate, so any drift affects
both alike, and the last column is the second binary's median as a share of
the first's. Build ReleaseSafe binaries, the mode releases ship in:

  zig build -Doptimize=ReleaseSafe --prefix /tmp/before
  python3 tools/benchmark.py [--runs N] [--only NAME] BINARY [BINARY]

--record rewrites benchmarks/baseline.md with one binary's medians and the
machine they came from; record only on a quiet machine. --expect rewrites
each program's .expected file from the first binary's output, for when a
program is added or deliberately changed.
"""

import argparse
import datetime
import pathlib
import platform
import statistics
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parent.parent
suite = root / "benchmarks"


def run_once(binary, program):
    start = time.perf_counter()
    result = subprocess.run([binary, "run", str(program)], capture_output=True, text=True, encoding="utf-8")
    elapsed = time.perf_counter() - start
    return elapsed, result


def describe_machine():
    machine = f"{platform.system()} {platform.release()}, {platform.machine()}"
    if platform.system() == "Darwin":
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
        if chip:
            machine += f", {chip}"
    return machine


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binaries", nargs="+", help="one emerald binary, or two to compare")
    parser.add_argument("--runs", type=int, default=5, help="runs of each program per binary (default 5)")
    parser.add_argument("--only", help="run only the program with this name, such as fib")
    parser.add_argument("--record", action="store_true", help="write benchmarks/baseline.md from one binary")
    parser.add_argument("--expect", action="store_true", help="write each .expected file from the first binary")
    options = parser.parse_args()
    if len(options.binaries) > 2:
        parser.error("give one binary, or two to compare")
    if options.record and len(options.binaries) != 1:
        parser.error("--record takes one binary")

    programs = sorted(suite.glob("*.em"))
    if options.only:
        programs = [p for p in programs if p.stem == options.only]
        if not programs:
            parser.error(f"no benchmark named {options.only}")

    if options.expect:
        for program in programs:
            _, result = run_once(options.binaries[0], program)
            if result.returncode != 0:
                sys.exit(f"{program.name} failed:\n{result.stdout}{result.stderr}")
            program.with_suffix(".expected").write_text(result.stdout, encoding="utf-8")
            print(f"wrote {program.with_suffix('.expected').relative_to(root)}")
        return

    medians = {}
    wrong = False
    header = f"{'program':<12}" + "".join(f"{'binary ' + str(i + 1):>12}" for i in range(len(options.binaries)))
    if len(options.binaries) == 2:
        header += f"{'2 / 1':>10}"
    print(header)
    for program in programs:
        expected = program.with_suffix(".expected").read_text(encoding="utf-8")
        samples = [[] for _ in options.binaries]
        for _ in range(options.runs):
            for index, binary in enumerate(options.binaries):
                elapsed, result = run_once(binary, program)
                if result.returncode != 0 or result.stdout != expected:
                    print(f"{program.stem}: binary {index + 1} printed the wrong answer:\n{result.stdout}{result.stderr}")
                    wrong = True
                samples[index].append(elapsed)
        row = [statistics.median(times) for times in samples]
        medians[program.stem] = row[0]
        line = f"{program.stem:<12}" + "".join(f"{seconds:>11.3f}s" for seconds in row)
        if len(row) == 2:
            line += f"{row[1] / row[0]:>10.2f}"
        print(line, flush=True)
    if wrong:
        sys.exit(1)

    if options.record:
        version = subprocess.run([options.binaries[0], "--version"], capture_output=True, text=True).stdout.strip()
        commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=root).stdout.strip()
        lines = [
            "# Benchmark baseline",
            "",
            "Written by `python3 tools/benchmark.py --record`. Each time is the median wall time of",
            f"{options.runs} runs of `emerald run`, startup included, with a ReleaseSafe build.",
            "",
            f"- Recorded: {datetime.date.today().isoformat()}",
            f"- Emerald: {version} (commit `{commit}`)",
            f"- Machine: {describe_machine()}",
            "",
            "Compare a change against a build of this commit with two binaries, not against these",
            "numbers: another machine, or a busy hour, moves every time.",
            "",
            "| Program | Median |",
            "| --- | --- |",
        ]
        lines += [f"| `{name}` | {seconds:.3f}s |" for name, seconds in medians.items()]
        (suite / "baseline.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {(suite / 'baseline.md').relative_to(root)}")


if __name__ == "__main__":
    main()
