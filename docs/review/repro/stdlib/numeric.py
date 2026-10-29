"""Int, Float, and Math against Python's int, float, decimal, and math (spec 5.3, 9.3, 9.4, 15.5)."""

import math
import random
import sys
from decimal import Decimal, ROUND_HALF_UP, ROUND_FLOOR, ROUND_CEILING, ROUND_DOWN, getcontext
getcontext().prec = 1200

from harness import Case, ERR, em_float, run

rng = random.Random(63)
MIN, MAX = -2**63, 2**63 - 1


def fits(v):
    return MIN <= v <= MAX


def em_int(v):
    if v == MIN:
        return "(-9223372036854775807 - 1)"
    return "(%d)" % v if v < 0 else str(v)


def display(x):
    """Emerald's Float display (9.4): shortest round-trip digits, fixed notation for
    1e-6 <= |x| < 1e16, otherwise scientific with a signed exponent."""
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0:
        return "-0.0" if math.copysign(1, x) < 0 else "0.0"
    sign = "-" if x < 0 else ""
    d = Decimal(repr(abs(x)))
    t = d.as_tuple()
    digits = "".join(map(str, t.digits)).rstrip("0") or "0"
    # value = 0.digits... scaled: position of the decimal point after the first digit
    exp10 = len(t.digits) + t.exponent - 1  # exponent of the leading digit
    ax = abs(x)
    if 1e-6 <= ax < 1e16:
        if exp10 >= 0:
            ip = digits[:exp10 + 1].ljust(exp10 + 1, "0")
            fp = digits[exp10 + 1:] or "0"
        else:
            ip = "0"
            fp = "0" * (-exp10 - 1) + digits
        return sign + ip + "." + fp
    mant = digits[0] + ("." + digits[1:] if len(digits) > 1 else "")
    return sign + mant + "e" + ("+" if exp10 >= 0 else "-") + str(abs(exp10))


def int_cases():
    cases = []
    specials = [0, 1, -1, 2, -2, 3, 7, -7, 10, 12, -12, 54, -54, 24, 255, -255, 1000, 999999,
                2**31, 2**32 + 1, 3037000499, 3037000500, -3037000500, 2**62, MAX, MIN, MAX - 1, MIN + 1]
    vals = specials + [rng.randint(-10**6, 10**6) for _ in range(30)] + [rng.randint(MIN, MAX) for _ in range(20)]
    pairs = [(a, b) for a in specials for b in specials] + [(rng.choice(vals), rng.choice(vals)) for _ in range(800)]
    for a, b in pairs:
        ea, eb = em_int(a), em_int(b)
        for op, f in (("+", lambda: a + b), ("-", lambda: a - b), ("*", lambda: a * b)):
            v = f()
            cases.append(Case("%s %s %s" % (ea, op, eb), v if fits(v) else ERR, "int%s %d %d" % (op, a, b)))
        if b == 0:
            cases += [Case("%s // %s" % (ea, eb), ERR, "int// %d 0" % a), Case("%s %% %s" % (ea, eb), ERR, "int%% %d 0" % a)]
        else:
            q = a // b
            cases.append(Case("%s // %s" % (ea, eb), q if fits(q) else ERR, "int// %d %d" % (a, b)))
            cases.append(Case("%s %% %s" % (ea, eb), a % b, "int%% %d %d" % (a, b)))
            cases.append(Case("%s / %s" % (ea, eb), display(a / b) if True else None, "int/ %d %d" % (a, b), raw=True))
        g = math.gcd(a, b)
        cases.append(Case("%s.gcd(%s)" % (ea, eb), g if fits(g) else ERR, "gcd %d %d" % (a, b)))
        l = 0 if a == 0 or b == 0 else abs(a * b) // math.gcd(a, b)
        cases.append(Case("%s.lcm(%s)" % (ea, eb), l if fits(l) else ERR, "lcm %d %d" % (a, b)))
        if b != 0:
            cases.append(Case("%s.multiple_of?(%s)" % (ea, eb), a % b == 0, "multiple_of? %d %d" % (a, b)))
    for a in vals:
        ea = em_int(a)
        cases.append(Case("%s.abs()" % ea, abs(a) if fits(abs(a)) else ERR, "abs %d" % a))
        cases.append(Case("%s.digits()" % ea, [int(c) for c in str(abs(a))], "digits %d" % a))
        cases.append(Case("%s.format(group_digits: true)" % ea, "{:,}".format(a), "format %d" % a))
        cases.append(Case("%s.to_string()" % ea, str(a), "to_string %d" % a))
        cases.append(Case("%s.to_float()" % ea, display(float(a)), "to_float %d" % a, raw=True))
        for base in (2, 3, 8, 16, 36):
            cases.append(Case("%s.to_string(base: %d)" % (ea, base), to_base(a, base), "to_string(base:%d) %d" % (base, a)))
        for e in (0, 1, 2, 3, 5, 10, 63, -1):
            if e < 0:
                cases.append(Case("%s ** %s" % (ea, em_int(e)), ERR, "int** %d %d" % (a, e)))
            else:
                v = a ** e
                cases.append(Case("%s ** %d" % (ea, e), v if fits(v) else ERR, "int** %d %d" % (a, e)))
        cases.append(Case("-%s" % ea, -a if fits(-a) else ERR, "neg %d" % a))
    for base in (1, 37, 0, -2):
        cases.append(Case("10.to_string(base: %s)" % em_int(base), ERR, "to_string(base:%d)" % base))
    for n in list(range(0, 23)) + [-1]:
        cases.append(Case("%s.factorial()" % em_int(n), ERR if n < 0 or math.factorial(n) > MAX else math.factorial(n), "factorial %d" % n))
    cases.append(Case("(-2) ** 63", MIN, "int** -2 63"))
    cases.append(Case("2 ** 3 ** 2", 512))
    cases.append(Case("-2 ** 2", -4))
    return cases


def to_base(a, base):
    if a == 0:
        return "0"
    digs = "0123456789abcdefghijklmnopqrstuvwxyz"
    n, out = abs(a), ""
    while n:
        out = digs[n % base] + out
        n //= base
    return ("-" if a < 0 else "") + out


def dround(x, places, mode=ROUND_HALF_UP):
    return float(Decimal(x).quantize(Decimal(1).scaleb(-places), rounding=mode))


def fmt_places(x, places, group=False):
    d = Decimal(x).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
    s = ("{:,.%df}" if group else "{:.%df}") % places
    return s.format(d)


def float_cases():
    cases = []
    specials = [0.0, -0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 0.49999999999999994, 2.675, 1.005, 0.125, 0.375,
                1e15, 1e16, 9007199254740993.0, 1e-6, 1e-7, 123456.789, -1234567.891, 0.1, 0.2, 0.3,
                1 / 3, 2 / 3, 1e300, 5e-324, 2.0 ** 62, 9.223372036854776e18, -9.223372036854776e18,
                4.35, 8.345, 1.45, 0.045, 1234.5, 99.995, float("inf"), float("-inf"), float("nan"),
                1e22, 1.7976931348623157e308, 3.0, -7.0, 7.5, -7.5, 0.0001, 1.0000000000000002]
    vals = specials + [rng.uniform(-1000, 1000) for _ in range(60)] + [rng.choice([1, -1]) * 10 ** rng.uniform(-12, 20) for _ in range(60)] \
        + [round(rng.uniform(-100, 100), rng.randint(0, 3)) + rng.choice([0, 0.005, 0.05, 0.5]) for _ in range(60)]
    for x in vals:
        ex = em_float(x)
        fin = math.isfinite(x)
        cases.append(Case(ex, display(x), "display %r" % x, raw=True))
        cases.append(Case("%s.to_string().to_float()" % ex, display(x), "roundtrip %r" % x, raw=True))
        for name, mode in (("floor", ROUND_FLOOR), ("ceil", ROUND_CEILING), ("round", ROUND_HALF_UP), ("truncate", ROUND_DOWN), ("to_int", ROUND_DOWN)):
            if not fin:
                exp = ERR
            else:
                v = int(Decimal(x).to_integral_value(rounding=mode))
                exp = v if fits(v) else ERR
            cases.append(Case("%s.%s()" % (ex, name), exp, "%s %r" % (name, x)))
        for p in (-2, -1, 0, 1, 2, 3, 5):
            if not fin:
                exp = display(x)
            else:
                exp = display(dround(x, p))
            cases.append(Case("%s.round_to(%d)" % (ex, p), exp, "round_to(%d) %r" % (p, x), raw=True))
        for p in (0, 1, 2, 3):
            exp = fmt_places(x, p) if fin else display(x)
            cases.append(Case("%s.format(decimal_places: %d)" % (ex, p), exp, "format(dp:%d) %r" % (p, x)))
            if fin:
                cases.append(Case("%s.format(decimal_places: %d, group_digits: true)" % (ex, p), fmt_places(x, p, True), "format(dp:%d,group) %r" % (p, x)))
        cases.append(Case("%s.square_root()" % ex, display(math.sqrt(x)) if (x >= 0 or math.isnan(x)) else "NaN", "sqrt %r" % x, raw=True))
        cases.append(Case("%s.abs()" % ex, display(abs(x)), "fabs %r" % x, raw=True))
        for name, f in (("sin", math.sin), ("cos", math.cos), ("tan", math.tan), ("arc_sin", math.asin), ("arc_cos", math.acos),
                        ("arc_tan", math.atan), ("natural_log", math.log), ("log10", math.log10)):
            try:
                v = f(x)
            except (ValueError, OverflowError):
                v = float("nan")
                if name in ("natural_log", "log10") and x == 0:
                    v = float("-inf")
            cases.append(Case("Math.%s(%s)" % (name, ex), display(v), "Math.%s %r" % (name, x), raw=True, approx=True))
    pairs = [(a, b) for a in specials[:30] for b in specials[:30]] + [(rng.choice(vals), rng.choice(vals)) for _ in range(500)]
    for a, b in pairs:
        ea, eb = em_float(a), em_float(b)
        for op, f in (("+", lambda: a + b), ("-", lambda: a - b), ("*", lambda: a * b)):
            cases.append(Case("%s %s %s" % (ea, op, eb), display(f()), "f%s %r %r" % (op, a, b), raw=True))
        if b == 0:
            cases.append(Case("%s / %s" % (ea, eb), ERR, "f/ %r 0" % a))
            cases.append(Case("%s // %s" % (ea, eb), ERR, "f// %r 0" % a))
            cases.append(Case("%s %% %s" % (ea, eb), ERR, "f%% %r 0" % a))
        else:
            cases.append(Case("%s / %s" % (ea, eb), display(a / b), "f/ %r %r" % (a, b), raw=True))
            try:
                fd = a // b
            except (ValueError, OverflowError):
                fd = float("nan")
            cases.append(Case("%s // %s" % (ea, eb), display(fd), "f// %r %r" % (a, b), raw=True))
            if math.isnan(a) or math.isnan(b) or math.isinf(a) or math.isinf(b):
                fm = float("nan")
            else:
                fm = a % b
            cases.append(Case("%s %% %s" % (ea, eb), display(fm), "f%% %r %r" % (a, b), raw=True))
        try:
            pw = a ** b
            if isinstance(pw, complex):
                pw = float("nan")
        except ZeroDivisionError:
            pw = float("inf")  # 0.0 ** negative: IEEE pow gives +/-inf
            pw = math.pow(a, b) if False else (math.copysign(float("inf"), a) if b == int(b) and int(b) % 2 else float("inf"))
        except OverflowError:
            pw = float("inf") if a > 0 or (b == int(b) and int(b) % 2 == 0) else float("-inf")
        cases.append(Case("%s ** %s" % (ea, eb), display(pw), "f** %r %r" % (a, b), raw=True, approx=True))
        try:
            at = math.atan2(a, b)
        except ValueError:
            at = float("nan")
        cases.append(Case("Math.arc_tan2(%s, %s)" % (ea, eb), display(at), "Math.arc_tan2 %r %r" % (a, b), raw=True, approx=True))
        if math.isnan(a) or math.isnan(b):
            cases.append(Case("Math.max(%s, %s)" % (ea, eb), ERR, "Math.max %r %r" % (a, b)))
        else:
            cases.append(Case("Math.max(%s, %s)" % (ea, eb), display(a if a >= b else b), "Math.max %r %r" % (a, b), raw=True))
            cases.append(Case("Math.min(%s, %s)" % (ea, eb), display(a if a <= b else b), "Math.min %r %r" % (a, b), raw=True))
        # Math.log(value, base)
        try:
            lv = math.log(a, b)
        except (ValueError, ZeroDivisionError):
            lv = float("nan")
        cases.append(Case("Math.log(%s, %s)" % (ea, eb), display(lv), "Math.log %r %r" % (a, b), raw=True, approx=True))
    for p in (101, -1):
        cases.append(Case("1.5.format(decimal_places: %d)" % p, ERR, "format(dp:%d)" % p))
    cases += [
        Case("Math.min(3, 2.5)", "2.5", raw=True), Case("Math.max(3, 2.5)", "3.0", raw=True),
        Case("Math.max(0.0, -0.0)", "0.0", "Math.max(0.0,-0.0) gives first", raw=True),
        Case("Math.max(-0.0, 0.0)", "-0.0", "Math.max(-0.0,0.0) gives first", raw=True),
        Case('Math.max("b", "a")', "b", raw=True), Case("Math.max(2, 9)", "9", raw=True),
        Case("Math.pi", display(math.pi), raw=True), Case("Math.e", display(math.e), raw=True),
        Case("Math.power(2, 0.5)", display(2 ** 0.5), raw=True), Case("Math.power(-8, 1.0 / 3)", "NaN", raw=True),
        Case("Math.natural_log(0)", "-Infinity", raw=True), Case("Math.log(8, 1)", "NaN", raw=True),
        Case("Math.log(8, 2)", "3.0", raw=True), Case("Math.log(1000, 10)", "3.0", "Math.log(1000,10)", raw=True),
        Case("Math.log(0, 0)", "NaN", raw=True), Case("Math.log(-1, 2)", "NaN", raw=True),
        Case("Float.nan.round_to(2)", "NaN", raw=True), Case("Float.infinity.format(decimal_places: 2)", "Infinity", raw=True),
        Case("1.5.round_to(400)", "1.5", raw=True), Case("1.5.round_to(-400)", "0.0", raw=True),
        Case("(-1.5).round_to(-400)", "-0.0", raw=True), Case("1.5.round_to(-9223372036854775807 - 1)", "0.0", raw=True),
        Case("123.456.round_to(9223372036854775807)", "123.456", raw=True),
        Case("1e300.round_to(-300)", display(1e300), raw=True), Case("5e-324.round_to(400)", display(5e-324), raw=True),
        Case("0.1.format(decimal_places: 20)", fmt_places(0.1, 20)), Case("1e20.format(decimal_places: 0)", fmt_places(1e20, 0)),
        Case("1e300.format(decimal_places: 2)", fmt_places(1e300, 2), "1e300.format(dp:2)"),
        Case("5e-324.format(decimal_places: 100)", fmt_places(5e-324, 100), "5e-324.format(dp:100)"),
        Case("(-0.0).format(decimal_places: 2)", "-0.00", "-0.0.format(dp:2)"),
        Case("(-0.001).format(decimal_places: 2)", "-0.00", "-0.001.format(dp:2)"),
        Case("(-0.0).round()", 0), Case("(-0.5).round()", -1), Case("0.5.round()", 1),
        Case("9.223372036854776e18.to_int()", ERR), Case("(-9.223372036854776e18).to_int()", MIN),
        Case("7.0 % -2.0", display(7.0 % -2.0), raw=True), Case("(-7.0) % 2.0", display(-7.0 % 2.0), raw=True),
        Case("(-0.0) % 5.0", display(-0.0 % 5.0), "-0.0 % 5.0", raw=True), Case("1e-320 % -1.0", display(1e-320 % -1.0), raw=True),
        Case("(-1e-320) // 1.0", "-1.0", raw=True), Case("5 // 2.0", "2.0", raw=True),
        Case("Float.infinity // 1.0", "NaN", "inf//1.0", raw=True), Case("1.0 // Float.infinity", "0.0", "1.0//inf", raw=True),
        Case("(-1.0) // Float.infinity", "-1.0", "-1.0//inf", raw=True),
        Case("2.0.between?(1.0, Float.nan)", ERR), Case("Float.nan.between?(1.0, 2.0)", False),
        Case("Float.nan.clamp(0.0, 1.0)", "NaN", raw=True), Case("5.clamp(9, 1)", ERR),
    ]
    return cases


def main():
    cases = int_cases() + float_cases()
    run(cases, "numbers", show=int(sys.argv[1]) if len(sys.argv) > 1 else 60)


if __name__ == "__main__":
    main()
