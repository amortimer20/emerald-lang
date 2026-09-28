#!/usr/bin/env python3
"""Measures how long Emerald takes to start and run small programs.

Every run of every program processes the prelude, so startup is most of
what a small program costs. This runs built binaries on a few programs and
reports, for each, the median wall time and the average user time, system
time, and page faults per run.

Absolute times drift with whatever else the machine is doing (on the
development machine, a quiet hour and a busy one differed by more than
two to one), so compare a change by giving two binaries: their runs
alternate, so any drift affects both alike, and the last column is the
second binary's median as a share of the first's. Record the output, with
the machine, in docs/journal.md.

  python3 tools/startup-benchmark.py [--runs N] BINARY [BINARY]

The programs are `print(1)`, which reaches no library code; a program
using only the language; and three that each reach one library.
"""

import argparse
import os
import pathlib
import platform
import resource
import statistics
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent.parent

PROGRAMS = {
    "print(1)": "print(1)\n",
    "structs (language only)": (root / "examples/structs.em").read_text(encoding="utf-8"),
    "dates": """const launch = Date(2026, 9, 28)
print(launch.add(days: 30), launch.weekday)
print(Duration(hours: 1, minutes: 30), Time(9, 45).add(minutes: 20))
""",
    "regex": (root / "examples/regex.em").read_text(encoding="utf-8"),
    "json": (root / "examples/json.em").read_text(encoding="utf-8"),
}


def usage():
    return resource.getrusage(resource.RUSAGE_CHILDREN)


def main():
    parser = argparse.ArgumentParser(description="Measure Emerald startup.")
    parser.add_argument("--runs", type=int, default=60)
    parser.add_argument("binaries", nargs="+", type=pathlib.Path)
    arguments = parser.parse_args()
    binaries = [binary.resolve() for binary in arguments.binaries]
    if len(binaries) > 2:
        sys.exit("give one binary to measure, or two to compare")

    with tempfile.TemporaryDirectory() as scratch:
        for index, binary in enumerate(binaries):
            version = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.strip()
            print(f"binary {index + 1}: {binary} ({version})")
        print(f"{arguments.runs} runs each, on {platform.system()} {platform.release()} ({os.cpu_count()} CPUs)")
        header = f"{'program':24}" + "".join(
            f" | {'wall':>9} {'user':>8} {'system':>8} {'faults':>6}" for _ in binaries
        )
        print(header + (" | second/first" if len(binaries) == 2 else ""))

        for name, text in PROGRAMS.items():
            path = pathlib.Path(scratch) / "program.em"
            path.write_text(text, encoding="utf-8")
            for binary in binaries:
                # A failing program would measure its error path, not a run.
                check = subprocess.run([binary, "run", path], capture_output=True)
                if check.returncode != 0:
                    sys.exit(f"{name} did not run cleanly with {binary}:\n{check.stderr.decode()}")
            walls = [[] for _ in binaries]
            user = [0.0 for _ in binaries]
            system = [0.0 for _ in binaries]
            faults = [0 for _ in binaries]
            for _ in range(arguments.runs):
                for index, binary in enumerate(binaries):
                    before = usage()
                    start = time.perf_counter()
                    subprocess.run([binary, "run", path], capture_output=True)
                    walls[index].append((time.perf_counter() - start) * 1000)
                    after = usage()
                    user[index] += after.ru_utime - before.ru_utime
                    system[index] += after.ru_stime - before.ru_stime
                    faults[index] += after.ru_minflt - before.ru_minflt
            line = f"{name:24}"
            medians = []
            for index in range(len(binaries)):
                median = statistics.median(walls[index])
                medians.append(median)
                line += (f" | {median:6.2f} ms {user[index] / arguments.runs * 1000:5.2f} ms"
                         f" {system[index] / arguments.runs * 1000:5.2f} ms {faults[index] / arguments.runs:6.0f}")
            if len(binaries) == 2:
                line += f" | {medians[1] / medians[0] * 100:5.1f}%"
            print(line)


main()
