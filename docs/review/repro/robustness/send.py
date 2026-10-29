#!/usr/bin/env python3
"""Replay one language-server reproduction.

Usage: python3 docs/review/repro/robustness/send.py BINARY NN-name.json

The .json file is a list of JSON-RPC messages. "$URI" is replaced by the file URI
of the matching NN-name.em (copied alone into a fresh directory as main.em), and
"$TEXT" by its contents. `initialize` and `didOpen` are sent first; `shutdown`
and `exit` last. Prints each reply, the exit status, and the server's stderr.
"""
import json, pathlib, subprocess, sys, tempfile

binary, request = sys.argv[1], pathlib.Path(sys.argv[2])
text = request.with_suffix(".em").read_bytes().decode()
work = pathlib.Path(tempfile.mkdtemp(prefix="emerald-repro-"))
(work / "main.em").write_bytes(text.encode())
uri = (work / "main.em").resolve().as_uri()


def fill(value):
    if isinstance(value, str):
        return {"$URI": uri, "$TEXT": text}.get(value, value)
    if isinstance(value, list):
        return [fill(v) for v in value]
    if isinstance(value, dict):
        return {k: fill(v) for k, v in value.items()}
    return value


messages = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": uri, "languageId": "emerald", "version": 1, "text": text}}}]
messages += fill(json.loads(request.read_text()))
messages += [{"jsonrpc": "2.0", "id": 9999, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
wire = b"".join(f"Content-Length: {len(b)}\r\n\r\n".encode() + b
                for b in (json.dumps(m).encode() for m in messages))
done = subprocess.run([binary, "lsp", "--stdio"], cwd=work, input=wire, capture_output=True, timeout=60)
rest = done.stdout
while rest:
    head, _, rest = rest.partition(b"\r\n\r\n")
    length = int(head.split(b":")[1])
    print(rest[:length].decode())
    rest = rest[length:]
print(f"exit status {done.returncode}")
print(done.stderr.decode(errors="replace")[:1500], end="")
