#!/usr/bin/env python3
"""Mutation robustness sweep for `check`, `format` and the language server.

Usage:
    python3 docs/review/repro/robustness/mutate.py BINARY [--out DIR] [--seed N]
        [--per-op N] [--jobs N] [--limit N] [--only SUBSTRING] [--no-lsp]

Every `.em` file under conformance/ and examples/ (sorted, so the set is stable)
yields `--per-op` mutants for each of six operators: delete a token, duplicate a
token, swap two adjacent tokens, truncate at a random byte, insert a keyword or
bracket, and replace an identifier with another identifier from the same file.
Each mutant's randomness is seeded from `--seed`, the file, the operator and the
index, so a run is reproducible and one mutant can be regenerated on its own.

Each mutant, written alone as `main.em` in a fresh directory, goes through:
  check          `emerald check main.em`
  format-check   `emerald format --check main.em`
  format         `emerald format main.em` twice (idempotence), then `check` on the
                 result when the mutant itself checked cleanly (format must not
                 break a program)
  lsp            `emerald lsp`: initialize, didOpen, then hover, completion,
                 definition, references, prepareRename, rename, signatureHelp and
                 codeAction at several positions, plus formatting and
                 documentSymbol; then didChange to the original text and a second
                 round; then shutdown and exit.

A finding is a signal or panic, a hang past the timeout, a leak report on exit,
an internal-failure exit (70), a non-idempotent format, a format that breaks a
checking program, an LSP reply that is not valid JSON-RPC (or a server that dies
or stops answering), an LSP internal error, a range outside the document, or
LSP formatting that disagrees with `emerald format`. Each is saved under
OUT/findings/ with the mutant, and OUT/summary.json gets the counts.
Use a Debug build: it carries the leak-checking allocator and safety checks.
"""
import argparse
import concurrent.futures as futures
import hashlib
import json
import os
from pathlib import Path
import queue
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[4]
KEYWORDS = [
    "and", "assert", "break", "case", "catch", "class", "const", "constructor",
    "continue", "else", "enum", "extends", "false", "finally", "for", "func", "if",
    "in", "is", "not", "nothing", "or", "raise", "return", "self", "struct", "super",
    "then", "trait", "true", "try", "using", "var", "when", "while", "with",
]
BRACKETS = ["(", ")", "[", "]", "{", "}", "#{", "\"", ",", ":", ".", "=", "=>", "->", "?", "\n"]
INSERTS = KEYWORDS + BRACKETS
OPS = ["delete", "duplicate", "swap", "truncate", "insert", "replace-ident"]

TOKEN = re.compile(
    r"""(?P<comment>\#(?!\{)[^\n]*)
      | (?P<string>"(?:\\.|[^"\\\n])*"?)
      | (?P<number>\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)
      | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<op>\.\.\.|\.\.<|\.\.|=>|->|==|!=|<=|>=|\+=|-=|\*=|/=|\?\?|\?\.|\*\*|::|[^\sA-Za-z0-9_])
      | (?P<space>\s+)""",
    re.X,
)
LEAK = re.compile(r"leaked|error\(gpa\)|error\(DebugAllocator\)|Double free|double free")
PANIC = re.compile(r"panic|reached unreachable|integer overflow|index out of bounds|"
                   r"Segmentation fault|Bus error|attempt to use null|incorrect alignment|"
                   r"cast truncated|invalid enum value|access of union field")


def tokens(text):
    out = []
    for match in TOKEN.finditer(text):
        kind = match.lastgroup
        if kind not in ("space", "comment"):
            out.append((match.start(), match.end(), kind))
    return out


def mutate(text, op, rng):
    """Return the mutant text, or None when the operator has nothing to act on."""
    toks = tokens(text)
    if op == "truncate":
        if len(text) < 2:
            return None
        cut = rng.randrange(1, len(text))
        return text.encode()[:cut].decode("utf-8", "ignore") if rng.random() < 0.5 else text[:cut]
    if not toks:
        return None
    if op == "delete":
        s, e, _ = rng.choice(toks)
        return text[:s] + text[e:]
    if op == "duplicate":
        s, e, _ = rng.choice(toks)
        return text[:e] + " " + text[s:e] + text[e:]
    if op == "swap":
        if len(toks) < 2:
            return None
        i = rng.randrange(len(toks) - 1)
        (a, b, _), (c, d, _) = toks[i], toks[i + 1]
        return text[:a] + text[c:d] + text[b:c] + text[a:b] + text[d:]
    if op == "insert":
        s, e, _ = rng.choice(toks)
        at = s if rng.random() < 0.5 else e
        word = rng.choice(INSERTS)
        return text[:at] + " " + word + " " + text[at:]
    if op == "replace-ident":
        idents = [t for t in toks if t[2] == "ident" and text[t[0]:t[1]] not in KEYWORDS]
        names = sorted({text[s:e] for s, e, _ in idents})
        if len(names) < 2:
            return None
        s, e, _ = rng.choice(idents)
        old = text[s:e]
        new = rng.choice([n for n in names if n != old])
        return text[:s] + new + text[e:]
    raise ValueError(op)


def sources():
    files = []
    for top in ("conformance", "examples"):
        files += sorted((ROOT / top).rglob("*.em"))
    return files


def generate(seed, per_op, only):
    for path in sources():
        rel = path.relative_to(ROOT).as_posix()
        if only and only not in rel:
            continue
        try:
            text = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            continue
        text = text.replace("/*cursor*/", "")
        for op in OPS:
            for k in range(per_op):
                rng = random.Random(f"{seed}:{rel}:{op}:{k}")
                mutant = mutate(text, op, rng)
                if mutant is None or mutant == text:
                    continue
                yield {"id": f"{rel}:{op}:{k}", "source": rel, "op": op, "text": mutant, "original": text}


def run(binary, args, cwd, timeout):
    started = time.monotonic()
    try:
        p = subprocess.run([binary, *args], cwd=cwd, capture_output=True, timeout=timeout)
        return {"code": p.returncode, "stdout": p.stdout.decode("utf-8", "replace"),
                "stderr": p.stderr.decode("utf-8", "replace"), "seconds": time.monotonic() - started}
    except subprocess.TimeoutExpired as error:
        return {"code": "timeout", "stdout": (error.stdout or b"").decode("utf-8", "replace"),
                "stderr": (error.stderr or b"").decode("utf-8", "replace"), "seconds": timeout}


def process_problem(result):
    """A crash-class problem in one process run, or None."""
    code = result["code"]
    if code == "timeout":
        return "hang"
    if isinstance(code, int) and code < 0:
        return f"signal {-code}"
    if LEAK.search(result["stderr"]):
        return "leak"
    if PANIC.search(result["stderr"]):
        return "panic"
    if code == 70:
        return "internal failure (exit 70)"
    return None


# ---------------------------------------------------------------- the language server

def frame(message):
    body = json.dumps(message).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def reader(stream, out):
    try:
        while True:
            length = None
            while True:
                line = stream.readline()
                if not line:
                    out.put(("eof", None))
                    return
                if line in (b"\r\n", b"\n"):
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1])
            if length is None:
                out.put(("bad-frame", "header without Content-Length"))
                return
            body = stream.read(length)
            try:
                out.put(("message", json.loads(body)))
            except Exception as error:
                out.put(("bad-json", f"{error}: {body[:200]!r}"))
                return
    except Exception as error:
        out.put(("bad-frame", repr(error)))


def utf16_lines(text):
    return [len(line.encode("utf-16-le")) // 2 for line in text.split("\n")]


def position_of(text, offset):
    before = text[:offset]
    line = before.count("\n")
    col = len(before.rsplit("\n", 1)[-1].encode("utf-16-le")) // 2
    return {"line": line, "character": col}


def check_ranges(value, uri, lines, problems, where):
    """Walk a reply and flag ranges for our document that fall outside it."""
    if isinstance(value, dict):
        r = value.get("range")
        target = value.get("uri", uri)
        if isinstance(r, dict) and target == uri:
            try:
                for end in ("start", "end"):
                    ln, ch = r[end]["line"], r[end]["character"]
                    if ln < 0 or ch < 0 or ln >= len(lines) or ch > lines[ln]:
                        problems.append(f"{where}: range {end} {ln}:{ch} outside the document")
                if (r["start"]["line"], r["start"]["character"]) > (r["end"]["line"], r["end"]["character"]):
                    problems.append(f"{where}: range start after end {r}")
            except (KeyError, TypeError):
                problems.append(f"{where}: malformed range {r!r}")
        for key, item in value.items():
            if key == "changes" and isinstance(item, dict):
                if uri in item:  # edits for other files of the project are not checked
                    check_ranges(item[uri], uri, lines, problems, where)
            elif key != "range":
                check_ranges(item, uri, lines, problems, where)
    elif isinstance(value, list):
        for item in value:
            check_ranges(item, uri, lines, problems, where)


def apply_edits(text, edits):
    lines = text.split("\n")
    starts = [0]
    for line in lines[:-1]:
        starts.append(starts[-1] + len(line) + 1)

    def offset(p):
        ln = min(p["line"], len(lines) - 1)
        units = lines[ln].encode("utf-16-le")[: p["character"] * 2]
        return starts[ln] + len(units.decode("utf-16-le", "ignore"))

    spans = sorted(((offset(e["range"]["start"]), offset(e["range"]["end"]), e["newText"]) for e in edits),
                   reverse=True)
    for s, e, new in spans:
        text = text[:s] + new + text[e:]
    return text


def lsp_session(binary, workdir, mutant, original, rng, timeout):
    path = Path(workdir) / "main.em"
    uri = path.resolve().as_uri()
    process = subprocess.Popen([binary, "lsp", "--stdio"], cwd=workdir,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    replies = queue.Queue()
    threading.Thread(target=reader, args=(process.stdout, replies), daemon=True).start()
    stderr_chunks = []
    threading.Thread(target=lambda: stderr_chunks.append(process.stderr.read()), daemon=True).start()
    problems = []
    sent = {}
    messages = []
    next_id = [0]

    def request(method, params):
        next_id[0] += 1
        sent[next_id[0]] = method
        messages.append({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params})

    def notify(method, params):
        messages.append({"jsonrpc": "2.0", "method": method, "params": params})

    def round_for(text):
        toks = tokens(text)
        offsets = [0, len(text)]
        for _ in range(4):
            if toks:
                s, e, _ = rng.choice(toks)
                offsets.append(rng.randint(s, e))
        doc = {"uri": uri}
        positions = [position_of(text, o) for o in offsets]
        positions.append({"line": text.count("\n") + 3, "character": 7})  # past the end
        for pos in positions:
            p = {"textDocument": doc, "position": pos}
            request("textDocument/hover", p)
            request("textDocument/completion", p)
            request("textDocument/definition", p)
            request("textDocument/references", {**p, "context": {"includeDeclaration": True}})
            request("textDocument/prepareRename", p)
            request("textDocument/rename", {**p, "newName": "renamed"})
            request("textDocument/signatureHelp", p)
            request("textDocument/codeAction", {"textDocument": doc, "range": {"start": pos, "end": pos},
                                                "context": {"diagnostics": []}})
        request("textDocument/formatting", {"textDocument": doc, "options": {"tabSize": 4, "insertSpaces": True}})
        request("textDocument/documentSymbol", {"textDocument": doc})

    request("initialize", {"processId": None, "rootUri": Path(workdir).resolve().as_uri(), "capabilities": {}})
    notify("initialized", {})
    notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "emerald", "version": 1, "text": mutant}})
    first_round_start = next_id[0] + 1
    round_for(mutant)
    first_round_end = next_id[0]
    notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                      "contentChanges": [{"text": original}]})
    round_for(original)
    notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 3},
                                      "contentChanges": [{"text": mutant}]})
    last_round = next_id[0] + 1
    request("textDocument/hover", {"textDocument": {"uri": uri}, "position": position_of(mutant, len(mutant) // 2)})
    notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    request("shutdown", None)
    notify("exit", None)

    def write_all():
        try:
            for m in messages:
                process.stdin.write(frame(m))
            process.stdin.flush()
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    threading.Thread(target=write_all, daemon=True).start()
    deadline = time.monotonic() + timeout
    pending = set(sent)
    texts = {}
    formatting_reply = None
    mutant_lines, original_lines = utf16_lines(mutant), utf16_lines(original)
    while pending:
        try:
            kind, payload = replies.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty:
            problems.append(f"hang: no reply to {len(pending)} requests, first {sent[min(pending)]} "
                            f"(id {min(pending)})")
            break
        if kind == "eof":
            problems.append(f"server died with {len(pending)} requests unanswered, first "
                            f"{sent[min(pending)]} (id {min(pending)})")
            break
        if kind != "message":
            problems.append(f"invalid frame: {kind}: {payload}")
            break
        m = payload
        if not isinstance(m, dict) or m.get("jsonrpc") != "2.0":
            problems.append(f"not JSON-RPC 2.0: {str(m)[:200]}")
            continue
        if "id" not in m:
            if m.get("method") == "textDocument/publishDiagnostics":
                lines = mutant_lines  # diagnostics may be for either text; check against the longer
                check_ranges(m.get("params", {}).get("diagnostics", []), uri,
                             [max(a, b) for a, b in zip(mutant_lines + [0] * len(original_lines),
                                                        original_lines + [0] * len(mutant_lines))],
                             problems, "publishDiagnostics")
            continue
        rid = m["id"]
        if rid not in pending:
            problems.append(f"reply to unknown or repeated id {rid}")
            continue
        pending.discard(rid)
        method = sent[rid]
        if ("result" in m) == ("error" in m):
            problems.append(f"{method} (id {rid}): reply has neither or both result and error")
            continue
        if "error" in m:
            err = m["error"]
            if not isinstance(err, dict) or not isinstance(err.get("code"), int) or "message" not in err:
                problems.append(f"{method} (id {rid}): malformed error {err!r}")
            elif err["code"] in (-32603, -32700, -32600):
                problems.append(f"{method} (id {rid}): error {err['code']} {err.get('message')}")
            continue
        in_first = first_round_start <= rid <= first_round_end or rid >= last_round
        check_ranges(m["result"], uri, mutant_lines if in_first else original_lines, problems,
                     f"{method} (id {rid}{'' if in_first else ', after didChange'})")
        if method == "textDocument/formatting" and in_first:
            formatting_reply = m["result"]
    try:
        process.wait(timeout=max(1, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        problems.append("server did not exit after `exit`")
    time.sleep(0.01)
    stderr = b"".join(stderr_chunks).decode("utf-8", "replace")
    if process.returncode is not None and process.returncode < 0:
        problems.append(f"signal {-process.returncode}")
    if LEAK.search(stderr):
        problems.append("leak reported on exit")
    if PANIC.search(stderr):
        problems.append("panic")
    return problems, stderr, formatting_reply


# ---------------------------------------------------------------- one mutant

def examine(binary, item, timeout, lsp):
    findings = []
    with tempfile.TemporaryDirectory(prefix="emut-") as tmp:
        check_dir, fmt_dir, lsp_dir = (Path(tmp) / d for d in ("c", "f", "l"))
        for d in (check_dir, fmt_dir, lsp_dir):
            d.mkdir()
            (d / "main.em").write_bytes(item["text"].encode("utf-8", "surrogatepass"))

        check = run(binary, ["check", "main.em"], check_dir, timeout)
        if (p := process_problem(check)):
            findings.append({"tool": "check", "kind": p, "stderr": check["stderr"][-3000:]})

        fcheck = run(binary, ["format", "--check", "main.em"], check_dir, timeout)
        if (p := process_problem(fcheck)):
            findings.append({"tool": "format-check", "kind": p, "stderr": fcheck["stderr"][-3000:]})

        f1 = run(binary, ["format", "main.em"], fmt_dir, timeout)
        formatted = None
        if (p := process_problem(f1)):
            findings.append({"tool": "format", "kind": p, "stderr": f1["stderr"][-3000:]})
        elif f1["code"] == 0:
            formatted = (fmt_dir / "main.em").read_bytes().decode("utf-8", "replace")
            f2 = run(binary, ["format", "main.em"], fmt_dir, timeout)
            if (p := process_problem(f2)):
                findings.append({"tool": "format (second pass)", "kind": p, "stderr": f2["stderr"][-3000:],
                                 "formatted": formatted})
            else:
                twice = (fmt_dir / "main.em").read_bytes().decode("utf-8", "replace")
                if twice != formatted:
                    findings.append({"tool": "format", "kind": "not idempotent",
                                     "formatted": formatted, "twice": twice})
            if check["code"] == 0:
                (fmt_dir / "main.em").write_bytes(formatted.encode())
                recheck = run(binary, ["check", "main.em"], fmt_dir, timeout)
                if recheck["code"] != 0:
                    findings.append({"tool": "format then check", "kind": "format broke a checking program",
                                     "formatted": formatted, "stderr": recheck["stderr"][-3000:],
                                     "stdout": recheck["stdout"][-3000:]})
            if check["code"] not in (0, "timeout") and isinstance(check["code"], int):
                pass

        if lsp:
            rng = random.Random("lsp:" + item["id"])
            problems, stderr, fmt_reply = lsp_session(binary, lsp_dir, item["text"], item["original"],
                                                      rng, timeout * 3)
            for problem in problems:
                findings.append({"tool": "lsp", "kind": problem, "stderr": stderr[-3000:]})
            if formatted is not None and isinstance(fmt_reply, list):
                via_lsp = apply_edits(item["text"], fmt_reply)
                if via_lsp != formatted:
                    findings.append({"tool": "lsp", "kind": "formatting disagrees with `emerald format`",
                                     "formatted": formatted, "lsp": via_lsp})
    return {"id": item["id"], "check": check["code"], "format": f1["code"], "findings": findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary")
    parser.add_argument("--out", default=None)
    parser.add_argument("--seed", type=int, default=20261028)
    parser.add_argument("--per-op", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--only", default="")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--no-lsp", action="store_true")
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    out = Path(args.out or tempfile.mkdtemp(prefix="emerald-mutate-"))
    (out / "findings").mkdir(parents=True, exist_ok=True)

    items = list(generate(args.seed, args.per_op, args.only))
    if args.limit:
        items = items[: args.limit]
    print(f"{len(items)} mutants, {args.jobs} jobs, results in {out}", flush=True)
    counts = {"mutants": 0, "check": 0, "format-check": 0, "format": 0, "lsp": 0 if args.no_lsp else 0}
    kinds = {}
    started = time.monotonic()
    with futures.ThreadPoolExecutor(args.jobs) as pool, open(out / "results.jsonl", "w") as log:
        jobs = {pool.submit(examine, binary, item, args.timeout, not args.no_lsp): item for item in items}
        for done, job in enumerate(futures.as_completed(jobs), 1):
            item = jobs[job]
            try:
                result = job.result()
            except Exception as error:
                result = {"id": item["id"], "findings": [{"tool": "harness", "kind": repr(error)}]}
            counts["mutants"] += 1
            counts["check"] += 1
            counts["format-check"] += 1
            counts["format"] += 1
            if not args.no_lsp:
                counts["lsp"] += 1
            log.write(json.dumps({k: v for k, v in result.items()}) + "\n")
            if result["findings"]:
                name = hashlib.sha1(item["id"].encode()).hexdigest()[:10]
                d = out / "findings" / name
                d.mkdir(exist_ok=True)
                (d / "main.em").write_bytes(item["text"].encode("utf-8", "surrogatepass"))
                (d / "info.json").write_text(json.dumps({"id": item["id"], **result}, indent=2))
                for f in result["findings"]:
                    key = f"{f['tool']}: {re.sub(r'id [0-9]+', 'id N', f['kind'])}"
                    kinds[key] = kinds.get(key, 0) + 1
                print(f"[{done}/{len(items)}] {item['id']}: "
                      + "; ".join(f"{f['tool']}: {f['kind']}" for f in result["findings"]), flush=True)
            elif done % 250 == 0:
                print(f"[{done}/{len(items)}] {time.monotonic() - started:.0f}s", flush=True)
    summary = {"seed": args.seed, "per_op": args.per_op, "runs": counts, "finding_kinds": kinds,
               "seconds": round(time.monotonic() - started)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
