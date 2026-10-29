"""Shared harness for the area-6 differential tests.

Each family script builds a list of Case values: an Emerald expression, the value the
reference (Python) gives for it, and a label. `run` writes one Emerald program with every
case wrapped in its own try/catch, runs it once, and compares each printed result with the
reference. Results are carried as JSON (`Json.encode`) unless a case asks for `raw`, in
which case the expression's display (string interpolation) is compared as text.

Run a family with `python3 docs/review/repro/stdlib/<family>.py` from the worktree root.
"""

import json
import math
import os
import subprocess
import sys
import tempfile
import unicodedata

sys.setrecursionlimit(20000)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
EMERALD = os.environ.get("EMERALD", os.path.join(ROOT, "zig-out", "bin", "emerald"))

ERR = object()  # expected: the operation raises


class Case:
    def __init__(self, expr, expected, label="", raw=False, approx=False, post=None):
        self.post = post
        self.expr = expr
        self.expected = expected
        self.label = label or expr
        self.raw = raw
        self.approx = approx


def em_str(s):
    """An Emerald double-quoted literal for any Python string."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "#":
            out.append("\\#")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif 0x20 <= o < 0x7F:
            out.append(ch)
        else:
            out.append("\\u{%X}" % o)
    out.append('"')
    return "".join(out)


def em_list(items, conv=em_str):
    return "[" + ", ".join(conv(x) for x in items) + "]"


def em_float(x):
    if math.isnan(x):
        return "Float.nan"
    if math.isinf(x):
        return "Float.infinity" if x > 0 else "(-Float.infinity)"
    r = repr(x)
    if "e" in r or "E" in r:
        mant, exp = r.lower().split("e")
        if "." not in mant:
            mant += ".0"
        r = mant + "e" + exp
    elif "." not in r:
        r += ".0"
    if r.startswith("-"):
        return "(" + r + ")"
    return r


def typed_eq(a, b, approx=False):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, float) or isinstance(b, float):
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            return False
        if type(a) is not type(b):
            return False
        if math.isnan(a) and math.isnan(b):
            return True
        if approx:
            return a == b or abs(a - b) <= 1e-12 * max(1.0, abs(a), abs(b))
        return a == b and math.copysign(1, a) == math.copysign(1, b)
    if isinstance(a, list) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(typed_eq(x, y, approx) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return list(a.keys()) == list(b.keys()) and all(typed_eq(a[k], b[k], approx) for k in a)
    return type(a) is type(b) and a == b


def program(cases, prelude=""):
    lines = [prelude] if prelude else []
    for i, c in enumerate(cases):
        if c.raw:
            body = 'print("C%d|#{%s}")' % (i, c.expr)
        else:
            body = 'print("C%d|" + Json.encode(%s))' % (i, c.expr)
        lines.append("try {\n    %s\n}\ncatch error {\n    print(\"C%d|ERR \" + error.message)\n}" % (body, i))
    return "\n".join(lines) + "\n"


def _exec(cases, idxs, prelude, timeout):
    """Run the cases at `idxs` as one program; returns ({index: text}, stderr, rc) or None on timeout."""
    sub = [cases[i] for i in idxs]
    src = program(sub, prelude)
    with tempfile.NamedTemporaryFile("w", suffix=".em", delete=False, encoding="utf-8") as f:
        f.write(src)
        path = f.name
    try:
        proc = subprocess.run([EMERALD, "run", path], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.unlink(path)
        return None
    os.unlink(path)
    results = {}
    for line in proc.stdout.decode("utf-8", "replace").split("\n"):
        if line.startswith("C") and "|" in line:
            idx, _, rest = line.partition("|")
            try:
                results[idxs[int(idx[1:])]] = rest
            except (ValueError, IndexError):
                pass
    return results, proc.stderr.decode("utf-8", "replace"), proc.returncode


def _run_range(cases, idxs, prelude, timeout, results, notes):
    r = _exec(cases, idxs, prelude, timeout)
    if r is None:
        if len(idxs) == 1:
            results[idxs[0]] = "HANG (no result within %ds)" % timeout
            return
        mid = len(idxs) // 2
        _run_range(cases, idxs[:mid], prelude, timeout, results, notes)
        _run_range(cases, idxs[mid:], prelude, timeout, results, notes)
        return
    res, err, rc = r
    if rc != 0 and not res:
        if len(idxs) == 1:
            results[idxs[0]] = "CRASH rc=%d %s" % (rc, err.strip().replace("\n", " / ")[:300])
            return
        if "^" in err and "panic" not in err.lower():
            print("PROGRAM REJECTED:\n" + err[:3000])
            sys.exit(1)
        mid = len(idxs) // 2
        _run_range(cases, idxs[:mid], prelude, timeout, results, notes)
        _run_range(cases, idxs[mid:], prelude, timeout, results, notes)
        return
    results.update(res)
    missing = [i for i in idxs if i not in res]
    if missing and rc != 0:
        # the program stopped part-way (an uncatchable failure): rerun the rest
        first = missing[0]
        results[first] = "CRASH rc=%d %s" % (rc, err.strip().replace("\n", " / ")[:300])
        rest = missing[1:]
        if rest:
            _run_range(cases, rest, prelude, timeout, results, notes)


def run(cases, family, prelude="", show=40):
    flt = os.environ.get("FILTER")
    if flt:
        cases = [c for c in cases if any(c.label.startswith(f) for f in flt.split(","))]
    chunk = int(os.environ.get("CHUNK", "1500"))
    timeout = int(os.environ.get("TIMEOUT", "240"))
    results, notes = {}, []
    for k in range(0, len(cases), chunk):
        _run_range(cases, list(range(k, min(k + chunk, len(cases)))), prelude, timeout, results, notes)

    class _P:
        returncode = 0
    proc = _P()
    mismatches = []
    for i, c in enumerate(cases):
        got = results.get(i)
        if got is None:
            mismatches.append((c, "<no output>"))
            continue
        if c.expected is ERR:
            if not got.startswith("ERR "):
                mismatches.append((c, got))
            continue
        if got.startswith("ERR "):
            mismatches.append((c, got))
            continue
        if c.raw:
            if got != c.expected:
                if c.approx:
                    try:
                        conv = lambda t: float(t.replace("Infinity", "inf"))
                        if typed_eq(conv(got), conv(c.expected), True):
                            continue
                    except ValueError:
                        pass
                mismatches.append((c, got))
            continue
        try:
            val = json.loads(got)
        except ValueError:
            mismatches.append((c, got))
            continue
        if c.post is not None:
            try:
                val = c.post(val)
            except Exception as exc:
                val = "<post failed: %s>" % exc
        if not typed_eq(val, c.expected, c.approx):
            mismatches.append((c, got))
    print("%s: %d cases, %d mismatches" % (family, len(cases), len(mismatches)))
    from collections import Counter
    kinds = Counter(c.label.split(" ")[0].split("(")[0] for c, _ in mismatches)
    if kinds:
        print("  by operation:", dict(kinds.most_common()))
    only = os.environ.get("ONLY")
    if only:
        mismatches = [m for m in mismatches if m[0].label.startswith(only)]
    for c, got in mismatches[:show]:
        exp = "ERR" if c.expected is ERR else (c.expected if c.raw else json.dumps(c.expected))
        if not got.startswith("ERR") and not c.raw:
            try:
                got = json.dumps(json.loads(got))
            except ValueError:
                pass
        print("  - %s\n      emerald:  %s\n      expected: %s" % (c.label, got, exp))
    return mismatches


# --- A simplified extended-grapheme segmenter, sufficient for the generated inputs ---------
# (combining marks, ZWJ emoji sequences, variation selectors, skin-tone modifiers, regional
# indicator pairs, CRLF, Hangul syllables are precomposed in the inputs).

def _is_extend(ch):
    o = ord(ch)
    cat = unicodedata.category(ch)
    return (cat in ("Mn", "Me") or o == 0x200D or 0xFE00 <= o <= 0xFE0F
            or 0x1F3FB <= o <= 0x1F3FF or cat == "Mc")


def graphemes(s):
    out = []
    i = 0
    while i < len(s):
        ch = s[i]
        j = i + 1
        if ch == "\r" and j < len(s) and s[j] == "\n":
            out.append("\r\n")
            i = j + 1
            continue
        if ch in "\r\n" or unicodedata.category(ch) == "Cc":
            out.append(ch)
            i = j
            continue
        if 0x1F1E6 <= ord(ch) <= 0x1F1FF and j < len(s) and 0x1F1E6 <= ord(s[j]) <= 0x1F1FF:
            j += 1
        while j < len(s):
            if _is_extend(s[j]):
                if ord(s[j]) == 0x200D and j + 1 < len(s):
                    j += 2
                else:
                    j += 1
            else:
                break
        out.append(s[i:j])
        i = j
    return out


def nfc(s):
    return unicodedata.normalize("NFC", s)
