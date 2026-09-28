#!/usr/bin/env python3
"""Compare Emerald Base64 encodings with Python's RFC 4648 implementation."""
import base64
import pathlib
import random
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
count = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
rng = random.Random(seed)
cases = [bytes(rng.randrange(256) for _ in range(rng.randrange(301))) for _ in range(count)]
source = "\n".join(
    f'print(Base64.encode(Bytes.from_list([{", ".join(map(str, item))}])))\n'
    f'print(Base64.encode(Bytes.from_list([{", ".join(map(str, item))}]), url_safe: true))'
    for item in cases
)
with tempfile.NamedTemporaryFile("w", suffix=".em", delete=False) as file:
    file.write(source)
    path = file.name
try:
    output = subprocess.check_output([root / "zig-out/bin/emerald", "run", path], text=True).splitlines()
finally:
    pathlib.Path(path).unlink(missing_ok=True)
expected = []
for item in cases:
    expected += [base64.b64encode(item).decode(), base64.urlsafe_b64encode(item).decode().rstrip("=")]
if output != expected:
    raise SystemExit("Base64 differential mismatch")


def run(program):
    with tempfile.NamedTemporaryFile("w", suffix=".em", delete=False) as file:
        file.write(program)
        name = file.name
    try:
        return subprocess.check_output([root / "zig-out/bin/emerald", "run", name], text=True).splitlines()
    finally:
        pathlib.Path(name).unlink(missing_ok=True)


def literal(text):
    return '"' + text.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace('"', '\\"') + '"'


# Decoding: Python writes each value, wrapped at a random width and with or
# without its padding; Emerald must read back the same bytes.
texts = []
for item in cases:
    text = base64.b64encode(item).decode()
    if rng.random() < 0.5:
        text = text.rstrip("=")
    width = rng.choice([0, 4, 60, 76])
    if width:
        ending = rng.choice(["\n", "\r\n"])
        text = ending.join(text[i : i + width] for i in range(0, len(text), width))
    texts.append(text)
decoded = run("\n".join(f"print(Base64.decode({literal(text)}).to_hex())" for text in texts))
if decoded != [item.hex() for item in cases]:
    raise SystemExit("Base64 decoding differential mismatch")

# Corruption: one character replaced by something outside the alphabet must be
# refused, as Python's validating decoder refuses it.
corrupted = []
for item in cases:
    text = base64.b64encode(item).decode()
    if not text:
        continue
    index = rng.randrange(len(text))
    text = text[:index] + rng.choice("!#%*.:?@-_") + text[index + 1 :]
    try:
        base64.b64decode(text, validate=True)
        continue  # still valid to Python, so not a corruption case
    except ValueError:
        corrupted.append(text)
refused = run("\n".join(f"print(Base64.decode_maybe({literal(text)}) == nothing)" for text in corrupted))
if refused != ["true"] * len(corrupted):
    raise SystemExit("Base64 corruption differential mismatch")

print(
    f"Base64 differential: {count * 2} encodings, {count} decodings, "
    f"{len(corrupted)} corruptions, seed {seed}, 0 differences"
)
