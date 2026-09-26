#!/usr/bin/env python3
"""Compares Emerald's regular-expression engine with Python's `re`.

Generates random patterns and texts where the two are meant to agree (ASCII
text without line breaks, and only constructs both support with the same
meaning), runs each through `tools/regex_probe.zig` and `re.search`, and
reports every difference in the first match or its groups. Two known,
deliberate differences are kept out of the generated cases: a repeated group
that can match nothing (Python, like Perl, takes one extra empty round and
records it; linear-time engines such as RE2, Go's, and Emerald's never take an
empty round), and `\B` on an empty text (Python's never matches there):

  python3 tools/regex-differential.py [count] [seed]

Needs `zig` on PATH. A local check, not part of `zig build test`: Python is
not a build dependency.
"""

import json
import pathlib
import random
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

ATOMS = ["a", "b", "c", ".", "[ab]", "[^a]", "[a-c]", r"\d", r"\w", r"\s", r"\W", "1", " "]
ANCHORS = ["^", "$", r"\b", r"\B"]
QUANTIFIERS = ["*", "+", "?", "{2}", "{1,2}", "{0,3}", "{2,}"]


def pattern(random, depth=0):
    items = []
    for _ in range(random.randint(1, 4)):
        roll = random.random()
        if roll < 0.12 and depth < 3:
            kind = random.choice(["(", "(?:"])
            inner = alternation(random, depth + 1)
            item = kind + inner + ")"
            if can_match_nothing(inner):
                items.append(item)
                continue
        elif roll < 0.2:
            items.append(random.choice(ANCHORS))
            continue
        else:
            item = random.choice(ATOMS)
        if random.random() < 0.35:
            item += random.choice(QUANTIFIERS)
            if random.random() < 0.3:
                item += "?"
        items.append(item)
    return "".join(items)


def can_match_nothing(source):
    try:
        return re.fullmatch(f"(?:{source})", "", re.ASCII) is not None or any(anchor in source for anchor in ANCHORS)
    except re.error:
        return True


def alternation(random, depth=0):
    branches = [pattern(random, depth) for _ in range(1 if random.random() < 0.7 else random.randint(2, 3))]
    return "|".join(branches)


def text(random):
    return "".join(random.choice("abc1 ") for _ in range(random.randint(0, 10)))


def python_groups(regex, subject):
    found = regex.search(subject)
    if found is None:
        return None
    return [list(found.span(number)) if found.span(number) != (-1, -1) else None for number in range(regex.groups + 1)]


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    generator = random.Random(seed)
    cases = []
    while len(cases) < count:
        source = alternation(generator)
        try:
            compiled = re.compile(source, re.ASCII)
        except re.error:
            continue
        ignore_case = generator.random() < 0.2
        if ignore_case:
            compiled = re.compile(source, re.ASCII | re.IGNORECASE)
        subject = text(generator)
        if subject == "" and r"\B" in source:
            continue
        cases.append((source, subject, ignore_case, python_groups(compiled, subject)))

    queries = "".join(json.dumps({"pattern": p, "text": t, "ignore_case": i}) + "\n" for p, t, i, _ in cases)
    result = subprocess.run(
        ["zig", "run", "--dep", "regex", "-Mroot=tools/regex_probe.zig", "-Mregex=src/Regex.zig"],
        input=queries, capture_output=True, text=True, cwd=ROOT, check=True,
    )
    answers = [json.loads(line) for line in result.stdout.splitlines()]
    differences = 0
    refused = 0
    for (source, subject, ignore_case, expected), answer in zip(cases, answers):
        if "error" in answer:
            refused += 1
            print(f"refused {source!r}: {answer['error']}")
            continue
        if answer["match"] != expected:
            differences += 1
            if differences <= 25:
                print(f"differs: {source!r} on {subject!r} (ignore_case={ignore_case}): Emerald {answer['match']}, Python {expected}")
    print(f"{len(cases)} cases, {differences} differences, {refused} refused")
    sys.exit(1 if differences or refused else 0)


if __name__ == "__main__":
    main()
