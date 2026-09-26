#!/usr/bin/env python3
"""Compares Emerald's JSON parser and writer with Python's `json`.

Generates random JSON documents and a smaller number of documents with one
common mistake introduced, runs each through `tools/json/probe.zig`, and
compares against Python's `json.loads`. For a well-formed document, both must
accept it and agree on the resulting value; for a mistaken one, both must
refuse it.

Two kinds of documents are excluded, both a deliberate, documented
difference from Python's `json`, which is more permissive than RFC 8259 in
these two ways: `NaN`/`Infinity`/`-Infinity`, which Python accepts as an
extension (docs/json-design-plan.md refuses them by name), and a duplicate
key, which Python keeps the last of (the plan refuses it, since in a
hand-written file that is almost always a mistake that would otherwise
silently discard data). The generator gives every key a running number, so
it never produces one on its own.

  python3 tools/json/differential.py [count] [seed]

Needs `zig` on PATH. A local check, not part of `zig build test`: Python is
not a build dependency.
"""

import json
import pathlib
import random
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

STRING_PIECES = list("abcXYZ 0129_-") + ["café", "😀", "\n", "\t", "\"", "\\", "/", "\u0001"]


def random_string(rng, key=None):
    body = "".join(rng.choice(STRING_PIECES) for _ in range(rng.randint(0, 5)))
    return f"{key}_{body}" if key is not None else body


def random_number(rng):
    if rng.random() < 0.5:
        return rng.randint(-10_000_000_000, 10_000_000_000)
    return round(rng.uniform(-1e8, 1e8), rng.randint(0, 6))


def random_value(rng, depth, next_key):
    kinds = ["null", "bool", "int", "float", "string", "list", "object"]
    weights = [1, 2, 3, 2, 3, 2, 2] if depth < 4 else [1, 2, 3, 2, 3, 0, 0]
    kind = rng.choices(kinds, weights=weights)[0]
    if kind == "null":
        return None
    if kind == "bool":
        return rng.choice([True, False])
    if kind == "int":
        return rng.randint(-(2**53), 2**53)
    if kind == "float":
        return float(random_number(rng))
    if kind == "string":
        return random_string(rng)
    if kind == "list":
        return [random_value(rng, depth + 1, next_key) for _ in range(rng.randint(0, 4))]
    entries = {}
    for _ in range(rng.randint(0, 4)):
        entries[random_string(rng, key=next_key())] = random_value(rng, depth + 1, next_key)
    return entries


def random_document(rng):
    counter = [0]

    def next_key():
        counter[0] += 1
        return f"k{counter[0]}"

    return json.dumps(random_value(rng, 0, next_key))


# Each mistake is applied to a piece already known to be there: `,]`/`,}` to
# introduce a trailing comma, and a plain key to strip its quotes. Only
# documents where the mistake actually changed the text are used.
def with_trailing_comma(text, rng):
    positions = [i for i, c in enumerate(text) if c in "]}" and i > 0 and text[i - 1] not in "[{"]
    if not positions:
        return None
    at = rng.choice(positions)
    return text[:at] + "," + text[at:]


def with_unquoted_key(text, rng):
    import re

    matches = list(re.finditer(r'"([A-Za-z_]\w*)":', text))
    if not matches:
        return None
    match = rng.choice(matches)
    return text[: match.start()] + match.group(1) + ":" + text[match.end() :]


def with_single_quotes(text, rng):
    positions = [i for i, c in enumerate(text) if c == '"']
    if not positions:
        return None
    at = rng.choice(positions)
    return text[:at] + "'" + text[at + 1 :]


MISTAKES = [with_trailing_comma, with_unquoted_key, with_single_quotes]


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    generator = random.Random(seed)

    cases = []  # (text, expect_ok, expected_value_or_None)
    while len(cases) < count:
        text = random_document(generator)
        if generator.random() < 0.25:
            mistake = generator.choice(MISTAKES)
            broken = mistake(text, generator)
            if broken is None or broken == text:
                continue
            cases.append((broken, False, None))
            continue
        cases.append((text, True, json.loads(text)))

    queries = "".join(json.dumps({"text": text}) + "\n" for text, _, _ in cases)
    result = subprocess.run(
        ["zig", "run", "--dep", "json", "-Mroot=tools/json/probe.zig", "-Mjson=src/Json.zig"],
        input=queries, capture_output=True, text=True, cwd=ROOT, check=True,
    )
    answers = [json.loads(line) for line in result.stdout.splitlines()]

    differences = 0
    for (text, expect_ok, expected), answer in zip(cases, answers):
        accepted = "ok" in answer
        if accepted != expect_ok:
            differences += 1
            if differences <= 25:
                state = "refused" if not accepted else f"accepted as {answer['ok']!r}"
                print(f"differs: {text!r}: Emerald {state}, expected {'accepted' if expect_ok else 'refused'}")
            continue
        if accepted and answer["ok"] != expected:
            differences += 1
            if differences <= 25:
                print(f"differs: {text!r}: Emerald {answer['ok']!r}, Python {expected!r}")

    print(f"{len(cases)} cases, {differences} differences")
    sys.exit(1 if differences else 0)


if __name__ == "__main__":
    main()
