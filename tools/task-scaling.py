#!/usr/bin/env python3
"""Check sequential task scaling on Linux; Windows CI uses its PowerShell driver."""

import argparse
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", help="a ReleaseSafe emerald binary")
    args = parser.parse_args()
    samples = {2000: [], 20000: []}
    for _ in range(3):
        for count in samples:
            result = subprocess.run(
                ["/usr/bin/time", "-f", "%e %M", args.binary, "run",
                 "tools/task-benchmark.em", "--", str(count)],
                capture_output=True, text=True, timeout=120,
            )
            expected = str(count * (count - 1) // 2) + "\n"
            if result.returncode != 0 or result.stdout != expected:
                raise SystemExit(f"{count} tasks failed: {result}")
            seconds, kib = result.stderr.split()
            samples[count].append((float(seconds), int(kib)))
    medians = {}
    for count, values in samples.items():
        seconds = statistics.median(v[0] for v in values)
        kib = statistics.median(v[1] for v in values)
        medians[count] = (seconds, kib)
        print(f"{count:,} tasks: {seconds:.2f} s, {kib / 1024:.2f} MiB peak RSS")
    small, large = medians[2000], medians[20000]
    print(f"Scaling: {large[0] / small[0]:.2f}x time, {large[1] / small[1]:.2f}x memory")
    if large[0] > small[0] * 15 or large[1] > small[1] * 2:
        raise SystemExit("task cost is not approximately linear with bounded memory")


if __name__ == "__main__":
    main()
