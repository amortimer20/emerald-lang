#!/usr/bin/env python3
"""Compare Emerald SHA-256 and HMAC-SHA256 with Python's hashlib and hmac."""
import hashlib, hmac, pathlib, random, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
count, seed = (int(sys.argv[1]), int(sys.argv[2])) if len(sys.argv) == 3 else (1000, 1)
rng = random.Random(seed)
cases = [(bytes(rng.randrange(256) for _ in range(rng.randrange(301))), bytes(rng.randrange(256) for _ in range(rng.randrange(161)))) for _ in range(count)]
def literal(value): return "[" + ", ".join(map(str, value)) + "]"
source = "\n".join(f"print(Digest.sha256(Bytes.from_list({literal(data)})).to_hex())\nprint(Digest.hmac_sha256(Bytes.from_list({literal(data)}), Bytes.from_list({literal(key)})).to_hex())" for data, key in cases)
with tempfile.NamedTemporaryFile("w", suffix=".em", delete=False) as file:
    file.write(source); path = pathlib.Path(file.name)
try: output = subprocess.check_output([root / "zig-out/bin/emerald", "run", path], text=True).splitlines()
finally: path.unlink(missing_ok=True)
expected = [item for data, key in cases for item in (hashlib.sha256(data).hexdigest(), hmac.new(key, data, hashlib.sha256).hexdigest())]
if output != expected: raise SystemExit("digest differential mismatch")
print(f"Digest differential: {count * 2} cases, seed {seed}, 0 differences")
