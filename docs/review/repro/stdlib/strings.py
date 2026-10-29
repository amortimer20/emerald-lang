"""String methods against Python, at the grapheme level the spec (9.1, 9.2) states."""

import itertools
import random
import re
import sys
import unicodedata

from harness import Case, ERR, em_str, graphemes, nfc, run

rng = random.Random(6)

WS = set(chr(c) for c in list(range(0x09, 0x0E)) + [0x20, 0x85, 0xA0, 0x1680]
         + list(range(0x2000, 0x200B)) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])

ATOMS = [
    "a", "b", "Z", "x", "1", "9", "0", " ", "  ", "\t", "\n", "\r\n", ",", "-", ".", "#",
    "\u00e9", "e\u0301", "\u00f1", "n\u0303", "\u00df", "\ufb01", "\u0130", "\u0131",
    "\u03a3", "\u03c3", "\u0416", "\u0436", "\u65e5", "\u672c", "\u8a9e",
    "\U0001F44B", "\U0001F44D\U0001F3FD", "\U0001F468\u200d\U0001F469\u200d\U0001F467",
    "\U0001F1EB\U0001F1F7", "\u2764\ufe0f", "\u00a0", "\u3000", "\u2003", "\u0085",
    "\u01c5", "\u216b", "\u0663", "\uff11",
]

WORDS = ["hello", "World", "caf\u00e9", "cafe\u0301", "na\u00efve", "\u65e5\u672c\u8a9e", "stra\u00dfe",
         "\U0001F44B\U0001F44B", "\u0416\u0443\u043a", "\u03a3\u03bf\u03c6\u03af\u03b1", "x", ""]


def rand_text(maxlen=6):
    return "".join(rng.choice(ATOMS) for _ in range(rng.randint(0, maxlen)))


def sample_inputs(n):
    fixed = ["", " ", "abc", "Hello, World", "  padded  ", "\t\n tabs \r\n",
             "caf\u00e9", "cafe\u0301", "\u65e5\u672c\u8a9e\u306e\u6587", "\U0001F44B hi \U0001F44B",
             "\U0001F468\u200d\U0001F469\u200d\U0001F467 family", "a,b,,c", "one\ntwo\r\nthree\n",
             "\u00a0\u3000wide\u3000\u00a0", "stra\u00dfe", "\u03a3\u0391\u03a3", "\ufb01ne", "\u0130stanbul"]
    return fixed + [rand_text() for _ in range(n)]


def is_ws_grapheme(g):
    return g[0] in WS


def ref_trim(s, start=True, end=True):
    g = graphemes(s)
    i, j = 0, len(g)
    if start:
        while i < j and is_ws_grapheme(g[i]):
            i += 1
    if end:
        while j > i and is_ws_grapheme(g[j - 1]):
            j -= 1
    return "".join(g[i:j])


def find_at(g, needle, start):
    """First grapheme index >= start where `needle` matches whole graphemes canonically;
    returns (i, j) or None."""
    target = nfc(needle)
    for i in range(start, len(g) + 1):
        acc = ""
        for j in range(i, len(g) + 1):
            if nfc(acc) == target and (j > i or needle == ""):
                return (i, j)
            if j < len(g):
                acc += g[j]
            if len(nfc(acc)) > len(target) + 8:
                break
    return None


def ref_index_of(s, needle):
    r = find_at(graphemes(s), needle, 0)
    return None if r is None else r[0]


def ref_split(s, sep):
    if sep == "":
        return ERR
    g = graphemes(s)
    out, pos = [], 0
    cur = 0
    while True:
        r = find_at(g, sep, cur)
        if r is None:
            break
        out.append("".join(g[pos:r[0]]))
        pos = cur = r[1]
    out.append("".join(g[pos:]))
    return out


def ref_replace(s, old, new):
    if old == "":
        return ERR
    parts = ref_split(s, old)
    return new.join(parts)


def ref_lines(s):
    if s == "":
        return []
    parts = s.split("\n")
    if s.endswith("\n"):
        parts = parts[:-1]
    return [p[:-1] if p.endswith("\r") else p for p in parts]


def ref_words(s):
    out, cur = [], ""
    for g in graphemes(s):
        if is_ws_grapheme(g):
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += g
    if cur:
        out.append(cur)
    return out


def ref_pad(s, width, fill, mode):
    if width < 0 or len(graphemes(fill)) != 1:
        return ERR
    n = len(graphemes(s))
    if n >= width:
        return s
    k = width - n
    if mode == "start":
        return fill * k + s
    if mode == "end":
        return s + fill * k
    left = k // 2
    return fill * left + s + fill * (k - left)


def ref_substring(s, start, count=None):
    g = graphemes(s)
    if start < 0 or start > len(g):
        return ERR
    if count is None:
        return "".join(g[start:])
    if count < 0 or start + count > len(g):
        return ERR
    return "".join(g[start:start + count])


INT_RE = re.compile(r"^[+-]?[0-9]+$")
FLOAT_RE = re.compile(r"^[+-]?([0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|Infinity|NaN)$")


def strip_ws(s):
    i, j = 0, len(s)
    while i < j and s[i] in WS:
        i += 1
    while j > i and s[j - 1] in WS:
        j -= 1
    return s[i:j]


def ref_to_int(s):
    t = strip_ws(s)
    if not INT_RE.match(t):
        return ERR
    v = int(t)
    if not -2**63 <= v < 2**63:
        return ERR
    return v


def ref_to_float(s):
    t = strip_ws(s)
    if not FLOAT_RE.match(t):
        return ERR
    return float(t.replace("Infinity", "inf"))


def alphabetic(cp):
    ch = chr(cp)
    cat = unicodedata.category(ch)
    return cat in ("Lu", "Ll", "Lt", "Lm", "Lo", "Nl")


def char_test(s, kind):
    g = graphemes(s)
    if not g:
        return False
    firsts = [x[0] for x in g]
    if kind == "letter":
        return all(alphabetic(ord(c)) for c in firsts)
    if kind == "digit":
        return all("0" <= c <= "9" for c in firsts)
    if kind == "whitespace":
        return all(c in WS for c in firsts)
    cased = [c for c in firsts if c.lower() != c or c.upper() != c or unicodedata.category(c) in ("Lu", "Ll", "Lt")]
    if not cased:
        return False
    if kind == "upper":
        return all(unicodedata.category(c) == "Lu" or (c.lower() != c and c.upper() == c) for c in cased)
    return all(unicodedata.category(c) == "Ll" or (c.upper() != c and c.lower() == c) for c in cased)


def main():
    cases = []
    inputs = sample_inputs(160)
    for s in inputs:
        e = em_str(s)
        g = graphemes(s)
        cases += [
            Case(e + ".count", len(g), "count %r" % s),
            Case(e + ".chars()", g, "chars %r" % s),
            Case(e + ".code_points()", [ord(c) for c in s], "code_points %r" % s),
            Case(e + ".bytes()", list(s.encode("utf-8")), "bytes %r" % s),
            Case(e + ".reverse()", "".join(reversed(g)), "reverse %r" % s),
            Case(e + ".upper()", s.upper(), "upper %r" % s),
            Case(e + ".lower()", s.lower(), "lower %r" % s),
            Case(e + ".capitalize()", (g[0].upper() + "".join(g[1:])) if g else "", "capitalize %r" % s),
            Case(e + ".trim()", ref_trim(s), "trim %r" % s),
            Case(e + ".trim_start()", ref_trim(s, end=False), "trim_start %r" % s),
            Case(e + ".trim_end()", ref_trim(s, start=False), "trim_end %r" % s),
            Case(e + ".blank?()", all(is_ws_grapheme(x) for x in g), "blank? %r" % s),
            Case(e + ".lines()", ref_lines(s), "lines %r" % s),
            Case(e + ".words()", ref_words(s), "words %r" % s),
            Case(e + ".to_int_maybe()", None if ref_to_int(s) is ERR else ref_to_int(s), "to_int_maybe %r" % s),
            Case(e + ".pad_start(8, \"*\")", ref_pad(s, 8, "*", "start"), "pad_start %r" % s),
            Case(e + ".pad_end(7)", ref_pad(s, 7, " ", "end"), "pad_end %r" % s),
            Case(e + ".pad_center(9, \"\\u{E9}\")", ref_pad(s, 9, "\u00e9", "center"), "pad_center %r" % s),
            Case(e + ".repeat(3)", s * 3, "repeat %r" % s),
        ]
        for kind in ("letter", "digit", "whitespace", "upper", "lower"):
            cases.append(Case(e + ".%s?()" % kind, char_test(s, kind), "%s? %r" % (kind, s)))
        for st in range(0, len(g) + 2):
            cases.append(Case(e + ".substring(%d)" % st, ref_substring(s, st), "substring(%d) %r" % (st, s)))
            for cnt in (0, 1, 2):
                cases.append(Case(e + ".substring(%d, %d)" % (st, cnt), ref_substring(s, st, cnt),
                                  "substring(%d,%d) %r" % (st, cnt, s)))
        # search with needles drawn from the text's own graphemes plus decoys
        needles = set(["a", "e", " ", ",", "\u00e9", "e\u0301", "\U0001F44B", "\u65e5", "ab", "\n"])
        if g:
            i = rng.randrange(len(g))
            needles.add("".join(g[i:i + rng.randint(1, 2)]))
        for nd in sorted(needles):
            en = em_str(nd)
            gi = ref_index_of(s, nd)
            gpre = find_at(graphemes(s), nd, 0)
            cases += [
                Case("%s.contains?(%s)" % (e, en), gi is not None, "contains? %r in %r" % (nd, s)),
                Case("%s.index_of(%s)" % (e, en), gi, "index_of %r in %r" % (nd, s)),
                Case("%s.starts_with?(%s)" % (e, en), gpre is not None and gpre[0] == 0 and nfc("".join(graphemes(s)[:gpre[1]])) == nfc(nd),
                     "starts_with? %r %r" % (nd, s)),
                Case("%s.split(%s)" % (e, en), ref_split(s, nd), "split %r by %r" % (s, nd)),
                Case("%s.replace(%s, \"<>\")" % (e, en), ref_replace(s, nd, "<>"), "replace %r in %r" % (nd, s)),
            ]
    # parsing
    nums = ["0", "42", "-7", "+3", " 12 ", "\t99\n", "1_000", "12a", "", " ", "-", "+", "007",
            "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809",
            "\u0663", "\uff11", "1.5", "1e3", "-0", "\u00a012\u3000", "0x10", "1 2"]
    floats = ["0", "1.5", "-2.25", "1e10", "1E-3", "+4.0", ".5", "5.", "1e", "Infinity", "-Infinity",
              "NaN", "inf", "nan", "infinity", "-NaN", "+Infinity", "1_0.0", " 3.25 ", "1e400", "-1e400",
              "4.9e-324", "2e-400", "0.1", "123456789012345678901234567890", "1.7976931348623157e308",
              "0x1p3", "1.5e+3", "--1", "\u00a01.0"]
    for s in nums:
        cases.append(Case(em_str(s) + ".to_int()", ref_to_int(s), "to_int %r" % s))
    for s in floats:
        exp = ref_to_float(s)
        if exp is not ERR and (exp != exp or exp in (float("inf"), float("-inf"))):
            cases.append(Case(em_str(s) + ".to_float()", {"nan": "NaN", "inf": "Infinity", "-inf": "-Infinity"}[repr(exp)], "to_float %r" % s, raw=True))
        else:
            cases.append(Case(em_str(s) + ".to_float()", exp, "to_float %r" % s))
    # pad errors
    cases += [
        Case('"hi".pad_start(-1)', ERR), Case('"hi".pad_start(4, "")', ERR), Case('"hi".pad_start(4, "ab")', ERR),
        Case('"hi".pad_start(4, "e\\u{301}")', "e\u0301e\u0301hi"),
        Case('"hi".pad_center(5, "-")', "-hi--"),
        Case('"".split(",")', [""]), Case('"".index_of("")', 0, '"".index_of("")'),
        Case('"abc".index_of("")', 0), Case('"abc".contains?("")', True),
        Case('"a".split("")', ERR), Case('"a".replace("", "x")', ERR),
        Case('"aaa".replace("aa", "b")', "ba"), Case('"aaaa".split("aa")', ["", "", ""]),
        Case('"caf\\u{E9}".contains?("e")', False), Case('"cafe\\u{301}".contains?("e")', False),
        Case('"cafe\\u{301}".contains?("\\u{E9}")', True), Case('"caf\\u{E9}".ends_with?("e\\u{301}")', True),
        Case('"\\u{1F468}\\u{200D}\\u{1F469}".contains?("\\u{1F469}")', False),
        Case('"x\\u{301}y".starts_with?("x")', False),
    ]
    run(cases, "strings", show=int(sys.argv[1]) if len(sys.argv) > 1 else 60)


if __name__ == "__main__":
    main()
