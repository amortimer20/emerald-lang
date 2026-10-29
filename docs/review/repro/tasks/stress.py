#!/usr/bin/env python3
"""Run Emerald programs repeatedly, in parallel, and tally every distinct outcome.

Usage: stress.py EMERALD_BINARY RUNS JOBS CASE [CASE ...]

A CASE is a path to a `.em` file. The program runs from its own directory's
parent when it sits under `conformance/` (so diagnostic paths match the golden
files), and from its own directory otherwise. A `.input` file beside it is fed
to standard input; otherwise standard input is empty. The reference is the
`.expected` file beside it when one exists; else the most frequent outcome.

Each run has a 20-second timeout. An outcome is (exit status, stdout+stderr).
A debug-allocator leak report shows up in the output and so as its own outcome.
"""
import collections
import concurrent.futures
import os
import subprocess
import sys

TIMEOUT = float(os.environ.get("STRESS_TIMEOUT", "20"))


def run_once(binary, case, cwd, rel, stdin_bytes, extra):
    try:
        done = subprocess.run(
            [binary, "run", rel, *extra],
            cwd=cwd,
            input=stdin_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=TIMEOUT,
        )
        return (done.returncode, done.stdout.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired as e:
        return ("TIMEOUT", (e.stdout or b"").decode("utf-8", "replace"))


def main():
    binary, runs, jobs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    extra = []
    cases = sys.argv[4:]
    if "--" in cases:
        i = cases.index("--")
        cases, extra = cases[:i], cases[i + 1 :]
    bad = 0
    for case in cases:
        case = os.path.abspath(case)
        parts = case.split(os.sep)
        if "conformance" in parts:
            k = len(parts) - 1 - parts[::-1].index("conformance")
            cwd = os.sep.join(parts[: k + 1])
        else:
            cwd = os.path.dirname(case)
        rel = os.path.relpath(case, cwd)
        stem = case[:-3]
        stdin_bytes = open(stem + ".input", "rb").read() if os.path.exists(stem + ".input") else b""
        expected = open(stem + ".expected").read() if os.path.exists(stem + ".expected") else None
        with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
            outcomes = collections.Counter(
                pool.map(lambda _: run_once(binary, case, cwd, rel, stdin_bytes, extra), range(runs))
            )
        if expected is not None:
            ok = sum(n for (code, out), n in outcomes.items() if out == expected and code != "TIMEOUT")
        else:
            ok = outcomes.most_common(1)[0][1]
        status = "OK " if ok == runs else "BAD"
        if ok != runs:
            bad += 1
        print(f"{status} {rel}: {ok}/{runs} match, {len(outcomes)} distinct outcome(s)", flush=True)
        if ok != runs or len(outcomes) > 1:
            for (code, out), n in outcomes.most_common():
                tag = "expected" if out == expected else "other"
                print(f"   {n:5d}x exit={code} [{tag}]")
                for line in out.splitlines()[:12]:
                    print(f"         | {line}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
