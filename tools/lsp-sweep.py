#!/usr/bin/env python3
"""Manual real-server QA: python3 tools/lsp-sweep.py BINARY [files/directories ...].

Defaults to every examples/**/*.em. One server per file; first sweep every character
boundary, then every unfinished prefix (every Nth boundary above 2 KiB, default N=8).
Latency includes framing and transport, but excludes didOpen analysis. A response
over 100 ms is reported; crashes, RPC errors, malformed JSON and 5 s hangs fail.
Use a ReleaseSafe binary. Not part of zig build test.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import queue
import statistics
import subprocess
import sys
import threading
import time


spec = importlib.util.spec_from_file_location(
    "completion_benchmark", Path(__file__).with_name("lsp-completion-benchmark.py")
)
framing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(framing)


class Server:
    def __init__(self, binary):
        self.process = subprocess.Popen(
            [binary, "lsp", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )
        self.replies = queue.Queue()
        self.next_id = 0
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            while True:
                self.replies.put(framing.receive(self.process))
        except Exception as error:
            self.replies.put(error)

    def send(self, message):
        framing.send(self.process, {"jsonrpc": "2.0", **message})

    def receive(self, deadline):
        try:
            response = self.replies.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty:
            raise RuntimeError("server did not reply within 5 seconds") from None
        if isinstance(response, Exception):
            raise RuntimeError(f"server crash or malformed frame: {response}")
        if not isinstance(response, dict) or response.get("jsonrpc") != "2.0":
            raise RuntimeError(f"malformed JSON-RPC reply: {response!r}")
        if "error" in response:
            raise RuntimeError(f"JSON-RPC error: {response['error']!r}")
        return response

    def call(self, method, params):
        self.next_id += 1
        started = time.perf_counter_ns()
        self.send({"id": self.next_id, "method": method, "params": params})
        deadline = time.monotonic() + 5
        response = self.receive(deadline)
        while response.get("method") == "textDocument/publishDiagnostics":
            # didClose publishes a clearing notification; a subsequent didOpen
            # can therefore leave one queued while its request is answered.
            response = self.receive(deadline)
        if response.get("id") != self.next_id or "result" not in response:
            raise RuntimeError(f"unexpected reply to {method}: {response!r}")
        return response["result"], (time.perf_counter_ns() - started) / 1_000_000

    def open(self, uri, text, version):
        self.send({"method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "emerald",
                             "version": version, "text": text}}})
        response = self.receive(time.monotonic() + 5)
        if response.get("method") != "textDocument/publishDiagnostics":
            raise RuntimeError(f"expected diagnostics: {response!r}")
        params = response.get("params", {})
        if params.get("uri") != uri or not isinstance(params.get("diagnostics"), list):
            raise RuntimeError(f"malformed diagnostics: {response!r}")
        return params["diagnostics"]

    def close_document(self, uri):
        self.send({"method": "textDocument/didClose", "params": {
            "textDocument": {"uri": uri}}})
        response = self.receive(time.monotonic() + 5)
        if (response.get("method") != "textDocument/publishDiagnostics"
                or response.get("params", {}).get("uri") != uri
                or response.get("params", {}).get("diagnostics") != []):
            raise RuntimeError(f"expected cleared diagnostics: {response!r}")

    def close(self, failed=False):
        # Always reap a failed server, without waiting on a hung request.
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=1)
        self.process.stdout.close()
        if self.process.returncode != 0 and not failed:
            raise RuntimeError(f"server exited with status {self.process.returncode}")


def boundaries(text):
    """Python offset, UTF-8 byte offset, and LSP UTF-16 position, including EOF."""
    line = character = byte = 0
    yield 0, byte, {"line": line, "character": character}
    for offset, char in enumerate(text, 1):
        byte += len(char.encode("utf-8"))
        if char == "\n":
            line += 1
            character = 0
        else:
            character += len(char.encode("utf-16-le")) // 2
        yield offset, byte, {"line": line, "character": character}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("paths", nargs="*", default=["examples"])
    parser.add_argument("--large-stride", type=int, default=8)
    parser.add_argument("--pass", dest="passes", choices=("both", "complete", "unfinished"), default="both")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.large_stride < 1:
        parser.error("--large-stride must be positive")
    files = set()
    for path in map(Path, args.paths):
        files.update(path.rglob("*.em") if path.is_dir() else [path])
    timings = {"textDocument/" + method: [] for method in
               ("hover", "completion", "signatureHelp", "codeAction")}
    slow = []
    context = {}
    started = time.monotonic()
    report = {"binary": str(Path(args.binary).resolve()), "large_stride": args.large_stride,
              "files": [], "slow": slow}

    def request(server, method, params):
        context["method"] = method
        result, elapsed = server.call(method, params)
        if method.endswith("completion") and not isinstance(result, (list, dict)):
            raise RuntimeError(f"malformed completion result: {result!r}")
        if method.endswith(("hover", "signatureHelp")) and result is not None and not isinstance(result, dict):
            raise RuntimeError(f"malformed {method} result: {result!r}")
        if method.endswith("codeAction") and result is not None and not isinstance(result, list):
            raise RuntimeError(f"malformed codeAction result: {result!r}")
        timings.setdefault(method, []).append(elapsed)
        if elapsed > 100:
            slow.append({**context, "method": method, "ms": elapsed})

    try:
        for document in sorted(files):
            text = document.read_bytes().decode("utf-8")
            uri = document.resolve().as_uri()
            positions = list(boundaries(text))
            context = {"file": str(document), "pass": "initialize"}
            server = Server(report["binary"])
            complete_count = unfinished_count = 0
            try:
                server.call("initialize", {"capabilities": {}})
                diagnostics = server.open(uri, text, 1)
                if args.passes != "unfinished":
                    for _, byte, position in positions:
                        context = {"file": str(document), "pass": "complete", "byte": byte, "position": position}
                        for method in ("hover", "completion", "signatureHelp"):
                            request(server, "textDocument/" + method,
                                    {"textDocument": {"uri": uri}, "position": position})
                        complete_count += 1
                    for diagnostic in diagnostics:
                        context = {"file": str(document), "pass": "diagnostic", "range": diagnostic["range"]}
                        request(server, "textDocument/codeAction", {
                            "textDocument": {"uri": uri}, "range": diagnostic["range"],
                            "context": {"diagnostics": [diagnostic]}})
                stride = args.large_stride if len(text.encode("utf-8")) > 2048 else 1
                if args.passes != "complete":
                    for index, (offset, byte, position) in enumerate(positions):
                        if index % stride and index != len(positions) - 1:
                            continue
                        context = {"file": str(document), "pass": "unfinished", "byte": byte, "position": position}
                        server.close_document(uri)
                        server.open(uri, text[:offset], index + 2)
                        for method in ("completion", "signatureHelp"):
                            request(server, "textDocument/" + method,
                                    {"textDocument": {"uri": uri}, "position": position})
                        unfinished_count += 1
                report["files"].append({"file": str(document), "bytes": len(text.encode("utf-8")),
                                        "complete_positions": complete_count,
                                        "unfinished_positions": unfinished_count, "stride": stride})
                print(json.dumps(report["files"][-1]), flush=True)
            finally:
                server.close(failed=sys.exc_info()[0] is not None)
    except Exception as error:
        report["failure"] = {**context, "error": str(error)}
        print(json.dumps(report["failure"]), file=sys.stderr, flush=True)
    finally:
        report["seconds"] = time.monotonic() - started
        report["latencies"] = {}
        for method, samples in timings.items():
            if not samples:
                report["latencies"][method] = {
                    "count": 0, "median_ms": None, "p95_ms": None, "max_ms": None}
                continue
            ordered = sorted(samples)
            report["latencies"][method] = {
                "count": len(samples), "median_ms": statistics.median(samples),
                "p95_ms": ordered[math.ceil(len(ordered) * .95) - 1], "max_ms": ordered[-1]}
        print(json.dumps({"latencies": report["latencies"], "slow": slow,
                          "seconds": report["seconds"]}), flush=True)
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    sys.exit(main())
