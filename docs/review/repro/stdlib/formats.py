"""Json, Csv, Regex, Base64, and Digest against Python's json, csv, re, base64, hashlib, hmac
(spec 15.4, 15.9, 15.11, 15.12)."""

import base64
import csv
import hashlib
import hmac
import io
import json
import math
import random
import re
import sys

from harness import Case, ERR, em_str, run

rng = random.Random(1512)


# ------------------------------------------------------------------ JSON
def rand_json(depth=0):
    r = rng.random()
    if depth > 3 or r < 0.45:
        k = rng.randint(0, 7)
        if k == 0:
            return None
        if k == 1:
            return rng.choice([True, False])
        if k == 2:
            return rng.randint(-10**6, 10**6)
        if k == 3:
            return rng.choice([0.5, -2.25, 1e-7, 1.5e300, 0.1, 123456.789, -0.0, 3.0, 1e16, 2.5e-308])
        return rand_jstr()
    if r < 0.7:
        return [rand_json(depth + 1) for _ in range(rng.randint(0, 4))]
    d = {}
    for _ in range(rng.randint(0, 4)):
        d[rand_jstr()] = rand_json(depth + 1)
    return d


def rand_jstr():
    pool = ["a", "Z", " ", "\"", "\\", "/", "\n", "\t", "\b", "\f", "\r", "\x00", "\x1f", "\x7f", "\u00e9", "e\u0301",
            "\u2028", "\u2029", "\U0001F44B", "\u65e5", "\ufeff", "#{x}", "\ud7ff", "\ue000", "\uffff"]
    return "".join(rng.choice(pool) for _ in range(rng.randint(0, 5)))


def strict_loads(text):
    def no_const(name):
        raise ValueError("constant " + name)

    def pairs(items):
        seen = set()
        for k, _ in items:
            import unicodedata
            nk = unicodedata.normalize("NFC", k)
            if nk in seen:
                raise ValueError("duplicate")
            seen.add(nk)
        return dict(items)

    def pf(s):
        v = float(s)
        if math.isinf(v):
            raise ValueError("too large")
        return v

    return json.loads(text, parse_constant=no_const, object_pairs_hook=pairs, parse_float=pf)


def json_cases():
    cases = []
    for _ in range(400):
        obj = rand_json()
        text = json.dumps(obj, ensure_ascii=rng.random() < 0.5, indent=rng.choice([None, 2]))
        # round-trip: Emerald's compact display must re-parse to the same document
        cases.append(Case("Json.parse(%s)" % em_str(text), obj, "json.parse roundtrip %s" % text[:60]))
        cases.append(Case("Json.encode(Json.parse(%s), pretty: true).split(\"\\n\")" % em_str(text), [json.dumps(l, ensure_ascii=False) and l for l in json.dumps(obj, indent=2, ensure_ascii=False).split("\n")], "json.pretty %s" % text[:60]))
    for _ in range(300):
        s = rand_jstr()
        cases.append(Case("Json.encode(%s)" % em_str(s), s, "json.encode string %r" % s, post=strict_loads))
        cases.append(Case("Json.parse(%s).string()" % em_str(json.dumps(s)), s, "json.decode string %r" % s))
    for x in [0.1, 1e16, 1e-7, 5e-324, 1.7976931348623157e308, -0.0, 3.0, 123456789.125, 1e21, 2 ** 53 + 0.0]:
        cases.append(Case("Json.encode(%r)" % x if x >= 0 and "inf" not in repr(x) else "Json.encode(%s)" % ("(" + repr(x) + ")"), x, "json.encode float %r" % x, post=strict_loads))
    for v in [0, -1, 2 ** 63 - 1, -2 ** 63 + 1]:
        cases.append(Case("Json.encode(%d)" % v if v >= 0 else "Json.encode((%d))" % v, v, "json.encode int %d" % v, post=strict_loads))
    texts = ['[1,2,]', "{'a':1}", '{a:1}', '[1] // c', 'NaN', '[Infinity]', '"abc', '01', '1.', '.5', '+1', '-', '-0', '1e5', '1E+2',
             '[1e400]', '[-1e400]', '"\\x41"', '"\\u00e9"', '"\\ud83d\\udc4b"', '"\\ud800"', '"\\udc00x"', '"\t"', '"\x01"', '{"a":1,"a":2}',
             '{"\\u00e9":1,"e\\u0301":2}', '\ufeff[1]', '[1]\u00a0', ' [1] ', '[] []', '', 'true', 'nul', '[1,]', '{"a" 1}', '12345678901234567890',
             '-9223372036854775808', '9223372036854775808', '1.0e-400', '"\\/"', '"\u2028"', '[' * 512 + ']' * 512, '[' * 513 + ']' * 513,
             '{"a":[1,{"b":null}]}', '0.0000001', '-0.0', '100000000000000000000000.0', '[1.5e300]']
    for t in texts:
        try:
            v = strict_loads(t)
            # 15.9: nesting deeper than 512 is refused
            depth = max((len(m) for m in re.findall(r"\[+", t)), default=0)
            exp = ERR if depth > 512 else v
        except (ValueError, RecursionError):
            exp = ERR
        if isinstance(exp, str) and any(0xD800 <= ord(c) <= 0xDFFF for c in exp):
            exp = ERR  # a lone surrogate is not a Unicode scalar value; Emerald strings cannot hold it
        cases.append(Case("Json.parse(%s)" % em_str(t), exp, "json.parse %r" % t[:40]))
    cases += [
        Case('Json.parse("3e2").int()', 300), Case('Json.parse("3.0").int()', 3), Case('Json.parse("3.5").int_maybe()', None),
        Case('Json.parse("9223372036854775807").int()', 2 ** 63 - 1), Case('Json.parse("9223372036854775808").int_maybe()', None),
        Case('Json.parse("1e19").int_maybe()', None), Case('Json.parse("-9223372036854775808").int()', -2 ** 63),
        Case('Json.parse("[1.0]") == Json.parse("[1]")', True), Case('Json.parse("{\\"a\\":1,\\"b\\":2}") == Json.parse("{\\"b\\":2,\\"a\\":1}")', True),
        Case('Json.from_float(3.0)', "3.0", raw=True), Case('Json.from_float(-0.0)', "-0.0", raw=True), Case('Json.from_float(Float.nan)', ERR),
        Case('Json.encode(Float.infinity)', ERR), Case('Json.parse("12345678901234567890").float()', 12345678901234567890.0, "json big int as float"),
        Case('Json.parse("0.1").float()', 0.1), Case('Json.parse("2.2250738585072011e-308").float()', 2.2250738585072011e-308, "json subnormal edge"),
        Case('Json.parse("1.00000000000000011102230246251565404236316680908203125").float()', 1.0, "json halfway rounding (ties to even)"),
    ]
    return cases


# ------------------------------------------------------------------ CSV
def rand_field():
    pool = ["a", "b", "1", ",", "\"", "\n", "\r\n", " ", ";", "\u00e9", "e\u0301", "\U0001F44B", "x y", "\t"]
    return "".join(rng.choice(pool) for _ in range(rng.randint(0, 4)))


def ref_format(rows, sep=","):
    out = []
    for row in rows:
        fields = []
        for f in row:
            if sep in f or '"' in f or "\n" in f or "\r" in f or f.startswith(" ") or f.endswith(" "):
                fields.append('"' + f.replace('"', '""') + '"')
            else:
                fields.append(f)
        out.append(sep.join(fields))
    return "\n".join(out)


def csv_cases():
    cases = []
    for _ in range(300):
        width = rng.randint(1, 4)
        rows = [[rand_field() for _ in range(width)] for _ in range(rng.randint(1, 4))]
        sep = rng.choice([",", ",", ";", "\t"])
        er = "[" + ", ".join("[" + ", ".join(em_str(f) for f in r) + "]" for r in rows) + "]"
        cases.append(Case("Csv.format(%s, separator: %s)" % (er, em_str(sep)), ref_format(rows, sep), "csv.format %r" % rows, raw=False))
        cases.append(Case("Csv.parse(Csv.format(%s, separator: %s), separator: %s)" % (er, em_str(sep), em_str(sep)), rows, "csv.roundtrip %r" % rows))
        # Python's writer output, parsed by Emerald, must read back to the rows
        buf = io.StringIO()
        csv.writer(buf, delimiter=sep, lineterminator="\r\n" if rng.random() < 0.5 else "\n", quoting=rng.choice([csv.QUOTE_MINIMAL, csv.QUOTE_ALL])).writerows(rows)
        text = buf.getvalue()
        exp = list(csv.reader(io.StringIO(text, newline=""), delimiter=sep))
        cases.append(Case("Csv.parse(%s, separator: %s)" % (em_str(text), em_str(sep)), exp, "csv.parse python-written %r" % text[:50]))
    for t, exp in [("a,b\n1,2", [["a", "b"], ["1", "2"]]), ("a,b\n1,2\n", [["a", "b"], ["1", "2"]]), ("\ufeffa,b", [["a", "b"]]),
                   ("a,\"b\"\"c\"", [["a", "b\"c"]]), ("a,\"b\nc\"", [["a", "b\nc"]]), ("", []), ("\n", [[""]]), ("a,b\r\n1,2\r\n", [["a", "b"], ["1", "2"]]),
                   ("a,\"b", ERR), ("a,b\"c", ERR), ("\"a\"b", ERR), ("a,,b", [["a", "", "b"]]), (",", [["", ""]]), ("a\n\nb", [["a"], [""], ["b"]]),
                   ("a\rb", [["a\rb"]])]:
        cases.append(Case("Csv.parse(%s)" % em_str(t), exp, "csv.parse %r" % t))
    cases += [
        Case('Csv.format([[""]])', '""', "csv.format single empty field"),
        Case('Csv.parse(Csv.format([[""]]))', [[""]], "csv.roundtrip single empty field"),
        Case('Csv.parse(Csv.format([["a"], [""], ["b"]]))', [["a"], [""], ["b"]], "csv.roundtrip empty row"),
        Case('Csv.parse("a;b", separator: "e\\u{301}")', [["a;b"]], "csv one-grapheme separator"),
        Case('Csv.parse("a,b", separator: ",,")', ERR), Case('Csv.parse("a,b", separator: "")', ERR),
        Case('Csv.parse("ae\\u{301}b", separator: "e")', [["ae\u0301b"]], "csv separator inside grapheme"),
        Case('Csv.parse_records("x,y\\n1,2\\n3,4")', [{"x": "1", "y": "2"}, {"x": "3", "y": "4"}]),
        Case('Csv.parse_records("x,x\\n1,2")', ERR), Case('Csv.parse_records("x,\\n1,2")', ERR), Case('Csv.parse_records("x,y\\n1")', ERR),
        Case('Csv.parse_records("")', []),
    ]
    return cases


# ------------------------------------------------------------------ Regex
PATTERNS = [r"\d+", r"[a-c]+", r"a|ab", r"ab|a", r"a*", r"a*?", r"(a|b)*c", r"\bfoo\b", r"\Bo", r"^a", r"a$", r"x?", r"[^a-z\s]+",
            r"\w+", r"\s+", r"a{2,3}", r"a{2,}?", r"(?:ab)+", r"(?<y>\d{4})-(\d\d)", r"\.", r"[\d.]+", r"colou?r", r"(a|)+b", r"",
            r"\b", r"[A-Z][a-z]*", r"a.c", r"\W", r"\D+", r"[-a]", r"[a\-z]", r"\S+", r"(foo|foobar)", r"(foobar|foo)", r"z*$"]
TEXTS_POOL = "aabc abcc foo foobar 2026-09-25 colour color Abc xyz  .. 12.5 - \n b ab a"


def go_findall(p, text):
    out, pos, prev_end = [], 0, -1
    while pos <= len(text):
        m = p.search(text, pos)
        if not m:
            break
        s, e = m.span()
        if s == e and s == prev_end:
            pos = s + 1
            continue
        out.append(m)
        prev_end = e
        pos = e if e > s else e + 1
    return out


def py_pattern(pat, multiline=False):
    # Emerald's `$` (without multiline) matches only at the very end: Python's `\Z`.
    if not multiline:
        pat = re.sub(r"(?<!\\)\$", r"\\Z", pat)
    pat = pat.replace("(?<", "(?P<")
    return re.compile(pat, re.ASCII | (re.MULTILINE if multiline else 0))


def regex_cases():
    cases = []
    for _ in range(500):
        pat = rng.choice(PATTERNS)
        k = rng.randint(0, 14)
        i = rng.randint(0, len(TEXTS_POOL) - k)
        text = TEXTS_POOL[i:i + k]
        p = py_pattern(pat)
        ms = go_findall(p, text)
        ep, et = "Regex(%s)" % em_str(pat), em_str(text)
        cases.append(Case("%s.find_all(%s).map { m => \"#{m.start}:#{m.end}:#{m.text}\" }" % (ep, et),
                          ["%d:%d:%s" % (m.start(), m.end(), m.group(0)) for m in ms], "regex.find_all /%s/ %r" % (pat, text)))
        cases.append(Case("%s.matches?(%s)" % (ep, et), p.fullmatch(text) is not None, "regex.matches? /%s/ %r" % (pat, text)))
        cases.append(Case("%s.contains_match?(%s)" % (ep, et), p.search(text) is not None, "regex.contains_match? /%s/ %r" % (pat, text)))
        rep, last = [], 0
        for m in ms:
            rep.append(text[last:m.start()])
            rep.append("<>")
            last = m.end()
        rep.append(text[last:])
        cases.append(Case("%s.replace_all(%s, \"<>\")" % (ep, et), "".join(rep), "regex.replace_all /%s/ %r" % (pat, text)))
        first = ms[0] if ms else None
        cases.append(Case("%s.replace(%s, \"$0\")" % (ep, et), (text[:first.start()] + "$0" + text[first.end():]) if first else text, "regex.replace /%s/ %r" % (pat, text)))
        pieces, last = [], 0
        for m in ms:
            if m.start() == m.end() and (m.start() == 0 or m.start() == len(text)):
                continue
            pieces.append(text[last:m.start()])
            last = m.end()
        pieces.append(text[last:])
        cases.append(Case("%s.split(%s)" % (ep, et), pieces, "regex.split /%s/ %r" % (pat, text)))
        # case-insensitive
        pi = re.compile(py_pattern(pat).pattern, re.ASCII | re.IGNORECASE)
        cases.append(Case("Regex(%s, ignore_case: true).find_all(%s).map { m => m.text }" % (em_str(pat), et),
                          [m.group(0) for m in go_findall(pi, text)], "regex.ignore_case /%s/ %r" % (pat, text)))
    for _ in range(80):
        text = "".join(rng.choice(["a", "b", "\n", " ", "1"]) for _ in range(rng.randint(0, 10)))
        for pat in (r"^\w+$", r"^", r"$", r"^a|b$"):
            p = py_pattern(pat, multiline=True)
            cases.append(Case("Regex(%s, multiline: true).find_all(%s).map { m => \"#{m.start}:#{m.end}\" }" % (em_str(pat), em_str(text)),
                              ["%d:%d" % m.span() for m in go_findall(p, text)], "regex.multiline /%s/ %r" % (pat, text)))
    for s in ["a.b*c", "(x)", "[a]", "\\d", "$5", "^", "{1}", "a|b", "", "\u00e9", "#"]:
        cases.append(Case("Regex(Regex.escape(%s)).matches?(%s)" % (em_str(s), em_str(s)), True, "regex.escape %r" % s))
    cases += [
        Case("Regex('[a-z]').contains_match?(\"\\u{E9}\")", False), Case("Regex('[a-z]').contains_match?(\"e\\u{301}\")", False),
        Case("Regex('.').find_all(\"e\\u{301}\\u{1F44B}\").count", 2, "regex dot is grapheme"),
        Case("Regex('\\u{E9}').contains_match?(\"e\\u{301}\")", True, "regex canonical literal"),
        Case("Regex('\\d').contains_match?(\"\\u{663}\")", False), Case("Regex('\\w').contains_match?(\"\\u{65E5}\")", True),
        Case("Regex('\\s').contains_match?(\"\\u{A0}\")", True),
        Case("Regex('STRASSE', ignore_case: true).matches?(\"stra\\u{DF}e\")", False, "regex simple case folding (no full folding)"),
        Case("Regex('\\u{3A3}', ignore_case: true).matches?(\"\\u{3C2}\")", True, "regex simple folding sigma"),
        Case("Regex('k', ignore_case: true).matches?(\"\\u{212A}\")", True, "regex Kelvin sign folds to k"),
        Case("Regex('(a|)*').find(\"b\").or_else_text()", "", "placeholder") if False else Case("Regex('(a|)+b').find(\"b\").or(Regex('x').find(\"x\").or(Regex('y').find(\"y\")!)).group_maybe(1) == nothing", True, "repeated group never takes an empty round") if False else Case("Regex('(\\d)(x)?').find(\"1\").map { m => m.group_maybe(2) == nothing }", True, "unset group via group_maybe") if False else Case("Regex(['a{1001}'][0]).pattern", ERR, "regex count above 1000"),
        Case("Regex(['(a)\\1'][0]).pattern", ERR), Case("Regex(['(?=a)'][0]).pattern", ERR), Case("Regex(['(?i)a'][0]).pattern", ERR), Case("Regex(['a++'][0]).pattern", ERR),
        Case("Regex('a{1000}').matches?(\"a\".repeat(1000))", True),
        Case("Regex('(a*)*b').contains_match?(\"a\".repeat(5000))", False, "regex pathological pattern stays linear"),
        Case("Regex('x*').split(\"axb\")", ["a", "b"]), Case("Regex(',').split(\",a,,b,\")", ["", "a", "", "b", ""]),
        Case("Regex('').split(\"abc\")", ["a", "b", "c"]),
        Case("Regex('a|b') == Regex('a|b')", True), Case("Regex('a') == Regex('a', ignore_case: true)", False),
    ]
    return cases


# ------------------------------------------------------------------ Base64 and digests
def em_bytes(b):
    return "Bytes.from_hex(%s)" % em_str(b.hex())


def b64_cases():
    cases = []
    for n in list(range(0, 10)) + [rng.randint(10, 300) for _ in range(60)]:
        b = bytes(rng.randrange(256) for _ in range(n))
        eb = em_bytes(b)
        std = base64.b64encode(b).decode()
        url = base64.urlsafe_b64encode(b).decode().rstrip("=")
        cases += [
            Case("Base64.encode(%s)" % eb, std, "b64.encode %d" % n),
            Case("Base64.encode(%s, url_safe: true)" % eb, url, "b64.encode url %d" % n),
            Case("Base64.decode(%s).to_hex()" % em_str(std), b.hex(), "b64.decode %d" % n),
            Case("Base64.decode(%s).to_hex()" % em_str(std.rstrip("=")), b.hex(), "b64.decode unpadded %d" % n),
            Case("Base64.decode(%s, url_safe: true).to_hex()" % em_str(url), b.hex(), "b64.decode url %d" % n),
            Case("Base64.decode(%s, url_safe: true).to_hex()" % em_str(url + "=" * (-len(url) % 4)), b.hex(), "b64.decode url padded %d" % n),
            Case("Base64.decode(%s).to_hex()" % em_str("\n".join(std[i:i + 4] for i in range(0, len(std), 4)) + " \t\r\n"), b.hex(), "b64.decode whitespace %d" % n),
            Case("Digest.sha256(%s).to_hex()" % eb, hashlib.sha256(b).hexdigest(), "sha256 %d" % n),
            Case("%s.to_hex()" % eb, b.hex(), "hex %d" % n),
            Case("Bytes.from_hex(%s).to_hex()" % em_str(b.hex().upper()), b.hex(), "from_hex upper %d" % n),
        ]
        for kl in (0, 1, 32, 64, 65, 200):
            k = bytes(rng.randrange(256) for _ in range(kl))
            cases.append(Case("Digest.hmac_sha256(%s, %s).to_hex()" % (eb, em_bytes(k)), hmac.new(k, b, hashlib.sha256).hexdigest(), "hmac msg %d key %d" % (n, kl)))
    for t in ["QR==", "QQ=", "Q===", "QQ==QQ==", "a+b_", "====", "Zg", "Zm9", "Zg=", "Z", "Zm9v!", "Zm 9v", "Zg==\n", "=Zg="]:
        try:
            raw = t.replace(" ", "").replace("\n", "")
            pad = raw + "=" * (-len(raw) % 4)
            if "+" in raw and "_" in raw:
                raise ValueError
            v = base64.b64decode(pad, validate=True)
            # RFC 4648 canonical check: re-encoding must give the same text (no stray bits)
            if base64.b64encode(v).decode().rstrip("=") != raw.rstrip("="):
                raise ValueError
            exp = v.hex()
        except Exception:
            exp = ERR
        cases.append(Case("Base64.decode(%s).to_hex()" % em_str(t), exp, "b64.decode %r" % t))
    cases += [
        Case('Digest.sha256("abc".to_bytes()).to_hex()', hashlib.sha256(b"abc").hexdigest()),
        Case('Digest.sha256(("a".repeat(1000000)).to_bytes()).to_hex()', hashlib.sha256(b"a" * 1000000).hexdigest(), "sha256 1MB"),
        Case('Bytes.from_hex("abc").count', ERR), Case('Bytes.from_hex("zz").count', ERR), Case('Bytes.from_hex_maybe("0g") == nothing', True),
        Case('Base64.decode_maybe("!") == nothing', True),
    ]
    return cases


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    show = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    fams = {"json": json_cases, "csv": csv_cases, "regex": regex_cases, "b64": b64_cases}
    for name, f in fams.items():
        if which in ("all", name):
            run(f(), name, show=show)


if __name__ == "__main__":
    main()
