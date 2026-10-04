#!/usr/bin/env python3
"""Exercise conformance/lsp documents through a real server process.

Usage: python3 tools/lsp-conformance.py BINARY [CASE ...] [--repeat N] [--show]
--show prints replies for review; it never writes or blesses expectations.
The Zig conformance runner separately runs each case 50 times under its allocator.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location("completion_benchmark", Path(__file__).with_name("lsp-completion-benchmark.py"))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)
receive, send = benchmark.receive, benchmark.send


def run_case(binary, case, repetitions, show):
    marked = case.read_text()
    if marked.count("/*cursor*/") != 1:
        raise RuntimeError(f"{case}: expected exactly one cursor marker")
    before, after = marked.split("/*cursor*/")
    text = before + after
    position = {"line": before.count("\n"),
                "character": len(before.rsplit("\n", 1)[-1].encode("utf-16-le")) // 2}
    stem = case.parent if case.name == "main.em" else case.with_suffix("")
    request = Path(str(stem) + ".request")
    method = request.read_text().strip() if request.exists() else "textDocument/completion"
    expected = Path(str(stem) + ".expected")
    process = subprocess.Popen([binary, "lsp", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        send(process, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}})
        receive(process)
        send(process, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": case.resolve().as_uri(), "languageId": "emerald",
                             "version": 1, "text": text}
        }})
        published = receive(process)
        rendered = ""
        for index in range(repetitions):
            params = {"textDocument": {"uri": case.resolve().as_uri()}}
            if method == "textDocument/codeAction":
                params.update(range={"start": position, "end": position},
                              context={"diagnostics": published["params"]["diagnostics"]})
            else:
                params["position"] = position
            send(process, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            reply = receive(process)
            normalize_uri(reply, case.resolve().as_uri())
            rendered = json.dumps(reply, ensure_ascii=False, indent=2) + "\n"
            if not show and rendered != expected.read_text():
                raise RuntimeError(f"{case}, execution {index + 1}: reply differs from {expected}\n{rendered}")
        if show:
            print(f"{case}:\n{rendered}", end="")
        else:
            print(f"{case}: {repetitions} identical replies")
    finally:
        process.stdin.close()
        process.wait(timeout=10)


def normalize_uri(value, uri):
    if isinstance(value, dict):
        for key, item in value.items():
            if item == uri:
                value[key] = "file:///document.em"
            else:
                normalize_uri(item, uri)
    elif isinstance(value, list):
        for item in value:
            normalize_uri(item, uri)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("cases", nargs="*")
    parser.add_argument("--repeat", type=int, default=50)
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()
    cases = [Path(case) for case in args.cases] if args.cases else sorted(
        path for path in Path("conformance/lsp").rglob("*.em") if "/*cursor*/" in path.read_text()
    )
    for case in cases:
        run_case(str(Path(args.binary).resolve()), case, args.repeat, args.show)


if __name__ == "__main__":
    main()
