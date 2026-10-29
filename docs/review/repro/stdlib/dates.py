"""Date, Time, DateTime, Duration, Instant, and TimeZone against Python's datetime and zoneinfo (spec 15.8)."""

import calendar
import datetime as dt
import random
import re
import sys
from zoneinfo import ZoneInfo

from harness import Case, ERR, em_str, run

rng = random.Random(158)


def add_months(d, months):
    total = d.year * 12 + (d.month - 1) + months
    y, m = divmod(total, 12)
    m += 1
    if not 1 <= y <= 9999:
        return None
    day = min(d.day, calendar.monthrange(y, m)[1])
    return dt.date(y, m, day)


def date_add(d, years=0, months=0, weeks=0, days=0):
    r = add_months(d, years * 12 + months)
    if r is None:
        return None
    try:
        return r + dt.timedelta(days=weeks * 7 + days)
    except OverflowError:
        return None


def units_until(a, b, step):
    cand = (b.year - a.year) * 12 + (b.month - a.month)
    cand = cand // step * step if cand >= 0 else -((-cand) // step * step)
    def at(k):
        return add_months(a, k)
    while cand > 0 and at(cand) > b:
        cand -= step
    while cand < 0 and at(cand) < b:
        cand += step
    # make sure we took the most
    while at(cand + step) is not None and cand >= 0 and at(cand + step) <= b and b >= a:
        cand += step
    while at(cand - step) is not None and cand <= 0 and at(cand - step) >= b and b <= a:
        cand -= step
    return cand // step


def em_date(d):
    return "Date(%d, %d, %d)" % (d.year, d.month, d.day)


def rand_date():
    if rng.random() < 0.5:
        y = rng.choice([1900, 2000, 2023, 2024, 2025, 2100, 1, 9999, 1600])
        m = rng.choice([1, 2, 3, 12])
        last = calendar.monthrange(y, m)[1]
        return dt.date(y, m, rng.choice([1, 28, last, min(29, last), min(30, last)]))
    return dt.date(rng.randint(1, 9999), rng.randint(1, 12), 1) + dt.timedelta(days=rng.randint(0, 27))


def frac(ns):
    if ns == 0:
        return ""
    s = "%09d" % ns
    while s.endswith("000"):
        s = s[:-3]
    return "." + s


def time_text(h, m, s, ns):
    return "%02d:%02d:%02d%s" % (h, m, s, frac(ns))


def duration_text(ns):
    if ns == 0:
        return "0s"
    sign = "-" if ns < 0 else ""
    n = abs(ns)
    d, n = divmod(n, 86400 * 10**9)
    h, n = divmod(n, 3600 * 10**9)
    m, n = divmod(n, 60 * 10**9)
    s, f = divmod(n, 10**9)
    parts = []
    if d:
        parts.append("%dd" % d)
    if h:
        parts.append("%dh" % h)
    if m:
        parts.append("%dm" % m)
    if s or f:
        fs = ("%09d" % f).rstrip("0")
        parts.append("%d%ss" % (s, "." + fs if fs else ""))
    return sign + " ".join(parts)


def main():
    cases = []
    weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    for _ in range(400):
        a = rand_date()
        b = rand_date() if rng.random() < 0.5 else a + dt.timedelta(days=rng.randint(-800, 800)) if dt.date(1, 3, 1) < a < dt.date(9997, 1, 1) else rand_date()
        ea, eb = em_date(a), em_date(b)
        cases += [
            Case(ea, a.isoformat(), "display %s" % a, raw=True),
            Case(ea + ".weekday", weekdays[a.weekday()], "weekday %s" % a, raw=True),
            Case(ea + ".day_of_year", a.timetuple().tm_yday, "day_of_year %s" % a),
            Case(ea + ".days_in_month", calendar.monthrange(a.year, a.month)[1], "days_in_month %s" % a),
            Case(ea + ".leap_year?()", calendar.isleap(a.year), "leap_year? %s" % a),
            Case(ea + ".month_name", calendar.month_name[a.month], "month_name %s" % a, raw=True),
            Case("%s.days_until(%s)" % (ea, eb), (b - a).days, "days_until %s %s" % (a, b)),
            Case("%s.months_until(%s)" % (ea, eb), units_until(a, b, 1), "months_until %s %s" % (a, b)),
            Case("%s.years_until(%s)" % (ea, eb), units_until(a, b, 12), "years_until %s %s" % (a, b)),
            Case("Date.parse(%s)" % em_str(" %s\n" % a.isoformat()), a.isoformat(), "parse %s" % a, raw=True),
            Case("%s < %s" % (ea, eb), a < b, "date< %s %s" % (a, b)),
        ]
        for kw in ({"months": rng.randint(-30, 30)}, {"years": rng.randint(-5, 5)}, {"days": rng.randint(-400, 400)},
                   {"weeks": rng.randint(-10, 10)}, {"years": 1, "months": -13, "days": 3}, {"months": 1}, {"months": -1},
                   {"years": 10000}, {"days": -10**6}):
            r = date_add(a, **kw)
            args = ", ".join("%s: %d" % (k, v) for k, v in kw.items())
            cases.append(Case("%s.add(%s)" % (ea, args), r.isoformat() if r else ERR, "add(%s) %s" % (args, a), raw=r is not None))
            neg = {k: -v for k, v in kw.items()}
            r2 = date_add(a, **neg)
            cases.append(Case("%s.subtract(%s)" % (ea, args), r2.isoformat() if r2 else ERR, "subtract(%s) %s" % (args, a), raw=r2 is not None))
    # Date construction validation and parsing
    for y, m, d in [(2026, 2, 29), (2024, 2, 29), (1900, 2, 29), (2000, 2, 29), (0, 1, 1), (10000, 1, 1), (2026, 13, 1), (2026, 4, 31), (2026, 0, 1), (2026, 1, 0)]:
        try:
            v = dt.date(y, m, d).isoformat()
        except ValueError:
            v = ERR
        cases.append(Case("Date(%d, %d, %d)" % (y, m, d), v, "construct %d-%d-%d" % (y, m, d), raw=v is not ERR))
    for text in ["2026-09-25", "2026-9-25", "20260925", "2026-02-30", "0001-01-01", "9999-12-31", "+2026-09-25", "2026-09-25T00:00",
                 "  2026-09-25  ", "2026/09/25", "10000-01-01", "2026-09-25 ", " 2026-09-25", "2026-١٢-01"]:
        try:
            ok = re.fullmatch(r"\s*(\d{4})-(\d{2})-(\d{2})\s*", text, re.ASCII)
            v = dt.date(int(ok[1]), int(ok[2]), int(ok[3])).isoformat() if ok else ERR
        except ValueError:
            v = ERR
        if text.startswith(" "):
            v = "2026-09-25"  # 9.4: surrounding whitespace is Unicode White_Space
        cases.append(Case("Date.parse(%s)" % em_str(text), v, "parse %r" % text, raw=v is not ERR))
    # Time
    for _ in range(200):
        h, m, s, ns = rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59), rng.choice([0, 0, 250000000, 1, 123456789, 500000])
        et = "Time(%d, %d, %d, %d)" % (h, m, s, ns)
        cases.append(Case(et, time_text(h, m, s, ns), "time display %s" % et, raw=True))
        cases.append(Case("Time.parse(%s)" % em_str(time_text(h, m, s, ns)), time_text(h, m, s, ns), "time parse %s" % et, raw=True))
        dh, dm, ds, dns = rng.randint(-50, 50), rng.randint(-200, 200), rng.randint(-5000, 5000), rng.randint(-10**10, 10**10)
        total = ((h * 60 + m) * 60 + s) * 10**9 + ns + ((dh * 60 + dm) * 60 + ds) * 10**9 + dns
        total %= 86400 * 10**9
        th, rem = divmod(total, 3600 * 10**9)
        tm, rem = divmod(rem, 60 * 10**9)
        ts, tns = divmod(rem, 10**9)
        cases.append(Case("%s.add(hours: %d, minutes: %d, seconds: %d, nanoseconds: %d)" % (et, dh, dm, ds, dns), time_text(th, tm, ts, tns),
                          "time add %s" % et, raw=True))
    for text, exp in [("14:30", "14:30:00"), ("14:30:00.25", "14:30:00.250"), ("14:30:00.123456789", "14:30:00.123456789"),
                      ("14:30:00.1234567891", ERR), ("24:00", ERR), ("14:60", ERR), ("14:30:60", ERR), ("1:30", ERR), ("14:30:00.", ERR),
                      ("14:30:00,5", ERR), (" 09:05 ", "09:05:00"), ("14:30:00.000", "14:30:00")]:
        cases.append(Case("Time.parse(%s)" % em_str(text), exp, "time parse %r" % text, raw=exp is not ERR))
    # DateTime
    for _ in range(200):
        a = rand_date()
        h = rng.randint(0, 23)
        mi = rng.randint(0, 59)
        x = dt.datetime(a.year, a.month, a.day, h, mi)
        ex = "DateTime(%d, %d, %d, %d, %d)" % (a.year, a.month, a.day, h, mi)
        mo, dd, hh = rng.randint(-14, 14), rng.randint(-40, 40), rng.randint(-100, 100)
        nd = add_months(a, mo)
        if nd is None:
            exp = ERR
        else:
            try:
                r = dt.datetime(nd.year, nd.month, nd.day, h, mi) + dt.timedelta(days=dd, hours=hh)
                exp = r.isoformat()
            except OverflowError:
                exp = ERR
        cases.append(Case("%s.add(months: %d, days: %d, hours: %d)" % (ex, mo, dd, hh), exp, "dt add %s" % ex, raw=exp is not ERR))
        b = rand_date()
        y = dt.datetime(b.year, b.month, b.day, rng.randint(0, 23))
        eb = "DateTime(%d, %d, %d, %d)" % (y.year, y.month, y.day, y.hour)
        diff = y - x
        cases.append(Case("%s.duration_until(%s)" % (ex, eb), duration_text((diff.days * 86400 + diff.seconds) * 10**9), "duration_until %s %s" % (ex, eb), raw=True))
        cases.append(Case("DateTime.parse(%s)" % em_str(x.isoformat(sep=rng.choice("T "))), x.isoformat(), "dt parse %s" % x, raw=True))
    cases.append(Case("DateTime(2026, 1, 31, 23).add(months: 1, hours: 2)", "2026-03-01T01:00:00", raw=True))
    # Duration
    for _ in range(300):
        kw = {k: rng.randint(-3, 3) * rng.choice([1, 10, 1000]) for k in rng.sample(["days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds"], 3)}
        mult = {"days": 86400 * 10**9, "hours": 3600 * 10**9, "minutes": 60 * 10**9, "seconds": 10**9, "milliseconds": 10**6, "microseconds": 1000, "nanoseconds": 1}
        ns = sum(v * mult[k] for k, v in kw.items())
        e = "Duration(%s)" % ", ".join("%s: %d" % kv for kv in kw.items())
        cases.append(Case(e, duration_text(ns), "duration display %s" % e, raw=True))
        k = rng.randint(-5, 5)
        cases.append(Case("%s * %d" % (e, k), duration_text(ns * k), "duration* %s" % e, raw=True))
        if k:
            q = abs(ns) // abs(k) * (1 if (ns >= 0) == (k > 0) else -1)
            cases.append(Case("%s / %d" % (e, k), duration_text(q), "duration/ %s %d" % (e, k), raw=True))
        for unit, div in (("hours", 3600 * 10**9), ("minutes", 60 * 10**9), ("seconds", 10**9), ("days", 86400 * 10**9)):
            w = abs(ns) // div * (1 if ns >= 0 else -1)
            cases.append(Case("%s.whole_%s" % (e, unit), w, "whole_%s %s" % (unit, e)))
            cases.append(Case("%s.total_%s" % (e, unit), ns / div, "total_%s %s" % (unit, e), approx=True))
        cases.append(Case("%s.abs()" % e, duration_text(abs(ns)), "duration abs %s" % e, raw=True))
    # Instants and zones
    zones = ["UTC", "America/New_York", "Europe/Paris", "Asia/Kolkata", "Australia/Lord_Howe", "America/Sao_Paulo", "Pacific/Apia", "Europe/London", "America/St_Johns"]
    for _ in range(300):
        secs = rng.randint(-2208988800, 4102444800)
        z = rng.choice(zones)
        local = dt.datetime.fromtimestamp(secs, ZoneInfo(z)).replace(tzinfo=None)
        cases.append(Case("Instant.from_unix_seconds(%d).to_date_time(TimeZone(%s))" % (secs, em_str(z)), local.isoformat(), "to_date_time %d %s" % (secs, z), raw=True))
        utc = dt.datetime.utcfromtimestamp(0) + dt.timedelta(seconds=secs)
        cases.append(Case("Instant.from_unix_seconds(%d)" % secs, utc.isoformat() + "Z", "instant display %d" % secs, raw=True))
        off = ZoneInfo(z).utcoffset(dt.datetime.fromtimestamp(secs, ZoneInfo(z)).replace(tzinfo=None) if False else dt.datetime.utcfromtimestamp(0).replace(tzinfo=dt.timezone.utc).astimezone(ZoneInfo(z)).replace(tzinfo=None) * 0 if False else None) if False else dt.datetime.fromtimestamp(secs, ZoneInfo(z)).utcoffset()
        cases.append(Case("TimeZone(%s).offset_at(Instant.from_unix_seconds(%d))" % (em_str(z), secs), duration_text(int(off.total_seconds()) * 10**9), "offset_at %d %s" % (secs, z), raw=True))
        # round trip a wall clock time through to_instant (non-ambiguous times only)
        lt = local.replace(minute=rng.randint(0, 59))
        a1 = lt.replace(tzinfo=ZoneInfo(z), fold=0)
        a2 = lt.replace(tzinfo=ZoneInfo(z), fold=1)
        if a1.utcoffset() == a2.utcoffset() and a1.astimezone(dt.timezone.utc).astimezone(ZoneInfo(z)).replace(tzinfo=None) == lt:
            u = int(a1.timestamp())
            cases.append(Case("DateTime(%d, %d, %d, %d, %d, %d).to_instant(TimeZone(%s)).unix_seconds" % (lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second, em_str(z)),
                              u, "to_instant %s %s" % (lt, z)))
    cases += [
        Case("DateTime(2026, 3, 8, 2, 30).to_instant(TimeZone(\"America/New_York\")).to_date_time(TimeZone(\"America/New_York\"))", "2026-03-08T03:30:00", "NY gap", raw=True),
        Case("DateTime(2026, 11, 1, 1, 30).to_instant(TimeZone(\"America/New_York\")).unix_seconds", int(dt.datetime(2026, 11, 1, 1, 30, tzinfo=ZoneInfo("America/New_York")).timestamp()), "NY fold earlier"),
        Case("Instant.from_unix_milliseconds(-1).unix_seconds", -1, "unix_seconds floors"),
        Case("Instant.from_unix_milliseconds(-1)", "1969-12-31T23:59:59.999Z", raw=True),
        Case("Duration(minutes: 90).whole_hours", 1), Case("Duration(minutes: -90).whole_hours", -1),
        Case("Duration(nanoseconds: -7) / 2", "-0.000000003s", raw=True),
        Case("Duration(hours: 1, minutes: 30) / Duration(minutes: 45)", 2.0),
        Case("TimeZone.fixed(hours: -5, minutes: 30).name", "-05:30", raw=True),
        Case("Date(2024, 2, 29).add(years: 1)", "2025-02-28", raw=True),
        Case("Date(2024, 2, 29).years_until(Date(2025, 2, 28))", 1, "leap birthday age"),
        Case("Date(2024, 1, 31).months_until(Date(2024, 2, 29))", 1),
        Case("Date(2024, 3, 31).months_until(Date(2024, 2, 29))", -1),
        Case("Date(2024, 3, 30).months_until(Date(2024, 2, 29))", -1),
    ]
    run(cases, "dates", show=int(sys.argv[1]) if len(sys.argv) > 1 else 60)


if __name__ == "__main__":
    main()
