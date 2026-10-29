"""List, Dict, and Set methods against Python (spec 8.4-8.6, docs/library/list.md, dict.md, set.md)."""

import math
import random
import sys
from collections import OrderedDict

from harness import Case, ERR, em_float, em_str, nfc, run

rng = random.Random(86)
WORDS = ["pear", "apple", "fig", "Banana", "kiwi", "café", "café", "éclair", "Zed", "", "a", "ab", "\U0001F44B", "日"]


def em_ints(xs):
    return "[" + ", ".join("(%d)" % x if x < 0 else str(x) for x in xs) + "]"


def em_floats(xs):
    return "[" + ", ".join(em_float(x) for x in xs) + "]"


def em_strs(xs):
    return "[" + ", ".join(em_str(x) for x in xs) + "]"


def fdisp(x):
    from numeric import display
    return display(x)


def key_str(s):
    # Emerald orders strings by normalized code points (9.2)
    return [ord(c) for c in nfc(s)]


def uniq(xs, key=lambda v: v):
    seen, out = set(), []
    for x in xs:
        k = key(x)
        if k not in seen:
            seen.add(k)
            out.append(x)
    return out


def main():
    cases = []
    typed = "const empty_ints: List[Int] = []\nconst empty_strs: List[String] = []\nconst empty_floats: List[Float] = []\n"
    for t in range(150):
        n = rng.randint(0, 9)
        ints = [rng.randint(-5, 5) for _ in range(n)]
        e = em_ints(ints) if ints else "empty_ints"
        cases += [
            Case(e + ".sort()", sorted(ints), "sort %r" % ints),
            Case(e + ".reverse()", ints[::-1], "reverse %r" % ints),
            Case(e + ".unique()", uniq(ints), "unique %r" % ints),
            Case(e + ".sum()", sum(ints), "sum %r" % ints),
            Case(e + ".average()", (sum(ints) / len(ints)) if ints else None, "average %r" % ints, approx=True),
            Case(e + ".min()", min(ints) if ints else None, "min %r" % ints),
            Case(e + ".max()", max(ints) if ints else None, "max %r" % ints),
            Case(e + ".index_of(1)", ints.index(1) if 1 in ints else None, "index_of %r" % ints),
            Case(e + ".repeat(2)", ints * 2, "repeat %r" % ints),
            Case(e + ".take(3)", ints[:3], "take %r" % ints), Case(e + ".drop(3)", ints[3:], "drop %r" % ints),
            Case(e + ".frequencies().keys()", uniq(ints), "frequencies.keys %r" % ints),
            Case(e + ".frequencies().values()", [ints.count(k) for k in uniq(ints)], "frequencies.values %r" % ints),
            Case(e + ".sort_by { x => x.abs() }", sorted(ints, key=abs), "sort_by abs %r" % ints),
            Case(e + ".sort_by { x => -x }", sorted(ints, key=lambda v: -v), "sort_by neg %r" % ints),
            Case(e + ".group_by { x => x % 3 }.values()", [[x for x in ints if x % 3 == k] for k in uniq([x % 3 for x in ints])], "group_by %r" % ints),
            Case(e + ".to_set().map { x => x }", uniq(ints), "to_set %r" % ints),
            Case(e + ".map { x => x.to_string() }.join(\",\")", ",".join(map(str, ints)), "join %r" % ints),
            Case(e + ".reduce(0) { acc, x => acc * 2 + x }", __import__("functools").reduce(lambda a, x: a * 2 + x, ints, 0), "reduce %r" % ints),
            Case(e + ".reduce_right(0) { acc, x => acc * 2 + x }", __import__("functools").reduce(lambda a, x: a * 2 + x, ints[::-1], 0), "reduce_right %r" % ints),
            Case(e + ".take_while { x => x < 3 }", list(__import__("itertools").takewhile(lambda v: v < 3, ints)), "take_while %r" % ints),
            Case(e + ".drop_while { x => x < 3 }", list(__import__("itertools").dropwhile(lambda v: v < 3, ints)), "drop_while %r" % ints),
            Case(e + ".unique_by { x => x.abs() }", uniq(ints, abs), "unique_by %r" % ints),
            Case(e + ".min_by { x => x.abs() }", min(ints, key=abs) if ints else None, "min_by %r" % ints),
            Case(e + ".max_by { x => x.abs() }", max(ints, key=abs) if ints else None, "max_by %r" % ints),
            Case(e + ".count_where { x => x > 0 }", sum(1 for x in ints if x > 0), "count_where %r" % ints),
            Case(e + ".one? { x => x == 0 }", ints.count(0) == 1, "one? %r" % ints),
            Case(e + ".flat_map { x => [x, x] }", [y for x in ints for y in (x, x)], "flat_map %r" % ints),
        ]
        for size in (1, 2, 3, 4):
            cases.append(Case("%s.chunks(%d)" % (e, size), [ints[i:i + size] for i in range(0, len(ints), size)], "chunks(%d) %r" % (size, ints)))
            cases.append(Case("%s.windows(%d)" % (e, size), [ints[i:i + size] for i in range(0, len(ints) - size + 1)], "windows(%d) %r" % (size, ints)))
        other = [rng.randint(0, 3) for _ in range(rng.randint(0, 6))]
        eo = em_ints(other) if other else "empty_ints"
        cases.append(Case("%s.zip(%s).map { (a, b) => a * 10 + b }" % (e, eo), [a * 10 + b for a, b in zip(ints, other)], "zip %r %r" % (ints, other)))
        cases.append(Case("%s.pairs().map { (a, b) => a - b }" % e, [a - b for a, b in zip(ints, ints[1:])], "pairs %r" % ints))
        # sets
        sa, sb = uniq(ints), uniq(other)
        mk = lambda xs: ("%s.to_set()" % em_ints(xs)) if xs else "empty_ints.to_set()"
        A, Bs = mk(sa), mk(sb)
        cases += [
            Case("%s.union(%s).map { x => x }" % (A, Bs), sa + [x for x in sb if x not in sa], "set.union %r %r" % (sa, sb)),
            Case("%s.intersection(%s).map { x => x }" % (A, Bs), [x for x in sa if x in sb], "set.intersection %r %r" % (sa, sb)),
            Case("%s.difference(%s).map { x => x }" % (A, Bs), [x for x in sa if x not in sb], "set.difference %r %r" % (sa, sb)),
            Case("%s.symmetric_difference(%s).map { x => x }" % (A, Bs), [x for x in sa if x not in sb] + [x for x in sb if x not in sa], "set.symdiff %r %r" % (sa, sb)),
            Case("%s.subset?(%s)" % (A, Bs), set(sa) <= set(sb), "set.subset? %r %r" % (sa, sb)),
            Case("%s.superset?(%s)" % (A, Bs), set(sa) >= set(sb), "set.superset? %r %r" % (sa, sb)),
            Case("%s.disjoint?(%s)" % (A, Bs), not (set(sa) & set(sb)), "set.disjoint? %r %r" % (sa, sb)),
            Case("%s == %s" % (A, Bs), set(sa) == set(sb), "set== %r %r" % (sa, sb)),
        ]
        # dicts: merge
        da = OrderedDict((str(k), i) for i, k in enumerate(ints))
        db = OrderedDict((str(k), 100 + i) for i, k in enumerate(other))
        prelude_d = None
        m = OrderedDict(da)
        for k, v in db.items():
            m[k] = v
        def emd(d):
            if not d:
                return "empty_dict()"
            return "[" + ", ".join("%s: %d" % (em_str(k), v) for k, v in d.items()) + "]"
        cases.append(Case("merged(%s, %s)" % (emd(da), emd(db)), dict(m), "dict.merge %r %r" % (dict(da), dict(db))))
        cases.append(Case("%s == %s" % (emd(da), emd(db)), dict(da) == dict(db), "dict== %r %r" % (dict(da), dict(db))))
        cases.append(Case("%s.map_values { v => v * 2 }" % emd(da), {k: v * 2 for k, v in da.items()}, "dict.map_values %r" % dict(da)))
        cases.append(Case(emd(da) + ".filter { (k, v) => v % 2 == 0 }", {k: v for k, v in da.items() if v % 2 == 0}, "dict.filter %r" % dict(da)))
        cases.append(Case("removed(%s, \"1\")" % emd(da), {k: v for k, v in list(da.items()) if k != "1"}, "dict.remove %r" % dict(da)))
    for t in range(80):
        n = rng.randint(0, 8)
        fl = [rng.choice([0.5, -0.0, 0.0, 1.25, -3.5, 2.0, 1e300, -1e-300, float("inf"), float("-inf"), 0.1, 0.2, 0.3]) for _ in range(n)]
        e = em_floats(fl) if fl else "empty_floats"
        srt = sorted(fl)  # Python's sort is stable; -0.0 and 0.0 are equal, so input order is kept
        cases.append(Case(e + ".sort().map { x => x.to_string() }", [fdisp(x) for x in srt], "fsort %r" % fl))
        cases.append(Case(e + ".min().or(42.0).to_string()", fdisp(min(fl)) if fl else "42.0", "fmin %r" % fl))
        cases.append(Case(e + ".max().or(42.0).to_string()", fdisp(max(fl)) if fl else "42.0", "fmax %r" % fl))
        s = 0.0
        for x in fl:
            s += x
        cases.append(Case(e + ".sum().to_string()", fdisp(s), "fsum %r" % fl))
        cases.append(Case(e + ".unique().map { x => x.to_string() }", [fdisp(x) for x in uniq(fl, key=lambda v: v)], "funique %r" % fl))
        words = [rng.choice(WORDS) for _ in range(rng.randint(0, 7))]
        ew = em_strs(words) if words else "empty_strs"
        cases.append(Case(ew + ".sort()", sorted(words, key=key_str), "ssort %r" % words))
        cases.append(Case(ew + ".sort_by { w => w.count }", sorted(words, key=lambda w: len(nfc(w))), "ssort_by count %r" % words))
        cases.append(Case(ew + ".unique()", uniq(words, key=nfc), "sunique %r" % words))
        cases.append(Case(ew + ".min()", min(words, key=key_str) if words else None, "smin %r" % words))
        cases.append(Case(ew + ".max()", max(words, key=key_str) if words else None, "smax %r" % words))
        cases.append(Case(ew + ".join(\"-\")", "-".join(words), "sjoin %r" % words))
        cases.append(Case(ew + ".frequencies().values()", [sum(1 for w in words if nfc(w) == nfc(k)) for k in uniq(words, key=nfc)], "sfrequencies %r" % words))
        cases.append(Case(ew + ".to_set().count", len(set(map(nfc, words))), "sto_set %r" % words))
    cases += [
        Case("[1.0, Float.nan].sort()", ERR), Case("[Float.nan].max()", ERR), Case("[1, 2].sort_by { x => Float.nan }", ERR),
        Case("[1].chunks(0)", ERR), Case("[1].windows(0)", ERR), Case("[1].take(-1)", ERR), Case("[1].repeat(-1)", ERR),
        Case("[9223372036854775807, 1].sum()", ERR),
        Case("[1.0, -0.0, 0.0].min().or(9.0).to_string()", "-0.0", "fmin first tie [1.0,-0.0,0.0]"),
        Case("[1.0, 0.0, -0.0].min().or(9.0).to_string()", "0.0", "fmin first tie [1.0,0.0,-0.0]"),
        Case("[0.0, -0.0].sort().map { x => x.to_string() }", ["0.0", "-0.0"], "fsort stable zeros"),
        Case("[-0.0, 0.0].sort().map { x => x.to_string() }", ["-0.0", "0.0"], "fsort stable zeros 2"),
        Case("[0.0, -0.0].unique().count", 1, "unique zeros"),
        Case("[(1, \"b\"), (0, \"a\"), (1, \"a\")].sort_by { p => p.0 }.map { p => p.1 }", ["a", "b", "a"], "sort_by stable tuples"),
        Case("[\"b\", \"B\", \"a\", \"A\"].sort()", ["A", "B", "a", "b"]),
        Case("[\"cafe\\u{301}\", \"caf\\u{E9}\"].sort()", ["café", "café"], "sort keeps canonically equal in input order"),
        Case("[\"caf\\u{E9}\", \"cafe\\u{301}\"].unique().count", 1),
        Case("[1, 2, 3].average()", 2.0), Case("[9223372036854775807, 9223372036854775807].average()", 9.223372036854776e18, "average large ints"),
        Case("[0.1, 0.2, 0.3].average()", (0.1 + 0.2 + 0.3) / 3, "average floats"),
    ]
    prelude = typed + """
func empty_dict(): Dict[String, Int] {
    const d: Dict[String, Int] = []
    return d
}

func merged(a: Dict[String, Int], b: Dict[String, Int]): Dict[String, Int] {
    var result = a
    result.merge(b)
    return result
}

func removed(a: Dict[String, Int], key: String): Dict[String, Int] {
    var result = a
    result.remove(key)
    return result
}
"""
    run(cases, "collections", prelude=prelude, show=int(sys.argv[1]) if len(sys.argv) > 1 else 60)


if __name__ == "__main__":
    main()
