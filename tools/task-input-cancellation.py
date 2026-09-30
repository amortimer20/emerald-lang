#!/usr/bin/env python3
"""Check cancellation with a live, held-open stdin pipe (no network)."""

import pathlib
import os
import queue
import subprocess
import sys
import threading


def check(binary, case, recover):
    arguments = [binary, "run", str(case)]
    if recover:
        arguments += ["--", "recover"]
    process = subprocess.Popen(
        arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8",
    )
    lines = queue.Queue()

    def collect():
        for line in process.stdout:
            lines.put(line)

    reader = threading.Thread(target=collect)
    reader.start()
    actual = []
    expected = ["input cleanup\n", "first failure\n"]
    if recover:
        expected += ["kept line\n"]
    expected += ["finished\n"]
    try:
        for wanted in expected:
            line = lines.get(timeout=5)
            actual.append(line)
            if line != wanted:
                raise AssertionError(f"wanted {wanted!r}, got {line!r}")
            if recover and line == "first failure\n":
                # Only supply data after cancellation and cleanup completed.
                # The original in-flight read must preserve this line.
                process.stdin.write("kept line\n")
                process.stdin.flush()
        # Deliberately keep stdin open: exiting must not join the reader.
        status = process.wait(timeout=5)
        reader.join(timeout=5)
        if reader.is_alive():
            raise AssertionError("stdout reader did not finish")
        if not lines.empty():
            raise AssertionError(f"unexpected extra output: {lines.get()!r}")
        errors = process.stderr.read()
        if status != 0 or errors:
            raise AssertionError(f"exit {status}, stderr {errors!r}")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdin.close()
        reader.join(timeout=5)
        process.stdout.close()
        process.stderr.close()


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    filename = "emerald.exe" if os.name == "nt" else "emerald"
    binary = sys.argv[1] if len(sys.argv) > 1 else str(root / "zig-out/bin" / filename)
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    case = root / "conformance/run/task-cancel-input-live.em"
    for _ in range(count):
        check(binary, case, False)
        check(binary, case, True)
    print(f"Live-input cancellation: {count} exit and {count} retained-line checks passed.")


if __name__ == "__main__":
    main()
