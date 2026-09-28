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
print(f"Base64 differential: {count * 2} encodings, seed {seed}, 0 differences")
