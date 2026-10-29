#!/usr/bin/env python3
"""Run an Emerald program repeatedly with a held-open standard-input pipe.

Usage: stdin_stress.py EMERALD RUNS JOBS PROGRAM.em DELAY LINE [LINE ...] [-- ARGS...]

Each run writes LINE after DELAY seconds (each further line after another DELAY),
then keeps the pipe open until the program exits or 15 seconds pass. Tallies
(exit status, output, whether it exited before the pipe closed).
"""
import collections
import concurrent.futures
import os
import subprocess
import sys
import threading
import time


def once(binary, program, delay, lines, args):
    start = time.time()
    proc = subprocess.Popen(
        [binary, "run", os.path.basename(program), *(["--", *args] if args else [])],
        cwd=os.path.dirname(os.path.abspath(program)),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    def feed():
        try:
            for line in lines:
                time.sleep(delay)
                proc.stdin.write((line + "\n").encode())
                proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    threading.Thread(target=feed, daemon=True).start()
    chunks = []
    reader = threading.Thread(target=lambda: chunks.append(proc.stdout.read()), daemon=True)
    reader.start()
    try:
        code = proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        reader.join()
        return ("TIMEOUT", b"".join(chunks).decode("utf-8", "replace"))
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
    reader.join()
    return (code, b"".join(chunks).decode("utf-8", "replace"))


def main():
    binary, runs, jobs, program, delay = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], float(sys.argv[5])
    rest = sys.argv[6:]
    args = []
    if "--" in rest:
        i = rest.index("--")
        rest, args = rest[:i], rest[i + 1 :]
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        tally = collections.Counter(pool.map(lambda _: once(binary, program, delay, rest, args), range(runs)))
    print(f"{program}: {len(tally)} distinct outcome(s) over {runs} runs")
    for (code, out), n in tally.most_common():
        print(f"   {n:5d}x exit={code}")
        for line in out.splitlines()[:10]:
            print(f"         | {line}")


if __name__ == "__main__":
    main()
