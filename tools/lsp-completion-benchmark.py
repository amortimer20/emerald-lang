#!/usr/bin/env python3
"""Measure real-server completion in the largest example project, without editing it.

Usage: python3 tools/lsp-completion-benchmark.py BEFORE AFTER [repetitions]
Both binaries should be ReleaseSafe builds. Only completion requests are timed;
server startup and didOpen's diagnostics are excluded.
"""
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time


def send(process, message):
    body = json.dumps(message).encode()
    process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    process.stdin.flush()


def receive(process):
    length = None
    while line := process.stdout.readline():
        if line == b"\r\n":
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    if length is None:
        raise RuntimeError("the language server closed before responding")
    return json.loads(process.stdout.read(length))


def measure(binary, document, suffix, repetitions):
    text = document.read_text() + "\n" + suffix
    uri = document.resolve().as_uri()
    process = subprocess.Popen(
        [binary, "lsp", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    try:
        send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        receive(process)
        send(process, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "emerald", "version": 1, "text": text}
        }})
        receive(process)  # published diagnostics, not part of completion latency
        times = []
        count = 0
        for index in range(repetitions + 5):
            request_id = index + 2
            started = time.perf_counter_ns()
            send(process, {"jsonrpc": "2.0", "id": request_id,
                "method": "textDocument/completion", "params": {
                    "textDocument": {"uri": uri},
                    "position": {"line": text.count("\n"),
                                 "character": len(text.rsplit("\n", 1)[-1])}
                }})
            response = receive(process)
            if response.get("id") != request_id or "result" not in response:
                raise RuntimeError(f"unexpected response: {response}")
            elapsed = (time.perf_counter_ns() - started) / 1_000_000
            count = len(response["result"])
            if index >= 5:
                times.append(elapsed)
        return statistics.median(times), count
    finally:
        process.stdin.close()
        process.wait(timeout=10)


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    repetitions = int(sys.argv[3]) if len(sys.argv) == 4 else 25
    document = Path(__file__).resolve().parent.parent / "examples/ledger/main.em"
    for suffix in ('func completion_probe() {\n    File.',
                   'func completion_probe() {\n    const completion_text = "abc"\n    completion_text.'):
        print(f"ledger project: {suffix.rsplit(chr(10), 1)[-1]}")
        for name, binary in zip(("before", "after"), sys.argv[1:3]):
            elapsed, count = measure(str(Path(binary).resolve()), document, suffix, repetitions)
            print(f"  {name}: median {elapsed:.3f} ms, {count} items, {repetitions} requests")


if __name__ == "__main__":
    main()
