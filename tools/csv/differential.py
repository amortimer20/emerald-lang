#!/usr/bin/env python3
"""Compares Emerald's CSV parser with Python's csv.reader.

Generated tables cover commas, semicolons, tabs, a Unicode separator, quotes,
line breaks in fields, a leading BOM, and Unix or Windows record endings. The
inputs come from Python's csv.writer, so both parsers should accept them and
produce the same rows.

  python3 tools/csv/differential.py [count] [seed]

Needs `zig` and Python 3 on PATH. It is a local review tool, not a build
dependency.
"""

import csv
import io
import json
import pathlib
import random
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SEPARATORS = [",", ";", "\t", "§"]
PIECES = ["", "Ada", "Hopper, Grace", " spaced ", 'said "hi"', "one\ntwo", "café", "😀", "x;y", "tab\tcell"]


def make_case(rng):
    separator = rng.choice(SEPARATORS)
    rows = [[rng.choice(PIECES) for _ in range(rng.randint(1, 5))] for _ in range(rng.randint(0, 6))]
    ending = rng.choice(["\n", "\r\n"])
    out = io.StringIO(newline="")
    csv.writer(out, delimiter=separator, lineterminator=ending).writerows(rows)
    text = out.getvalue()
    if rng.random() < 0.3:
        text = "\ufeff" + text
    expected = list(csv.reader(io.StringIO(text.removeprefix("\ufeff"), newline=""), delimiter=separator))
    return {"text": text, "separator": separator}, expected


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    cases = [make_case(rng) for _ in range(count)]
    queries = "".join(json.dumps(query, ensure_ascii=False) + "\n" for query, _ in cases)
    result = subprocess.run(
        ["zig", "run", "--dep", "csv", "-Mroot=tools/csv/probe.zig", "-Mcsv=src/Csv.zig"],
        input=queries,
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=True,
    )
    answers = [json.loads(line) for line in result.stdout.splitlines()]
    differences = 0
    for (query, expected), answer in zip(cases, answers):
        actual = answer.get("ok")
        if actual != expected:
            differences += 1
            if differences <= 25:
                print(f"differs: {query!r}: Emerald {answer!r}, Python {expected!r}")
    print(f"{len(cases)} cases, {differences} differences")
    sys.exit(1 if differences else 0)


if __name__ == "__main__":
    main()
