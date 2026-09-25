# Dates and times

Emerald has one type for each thing a program means by "a time", so the checker catches a
birthday used where a moment was meant (rewrite-context 15.8). Run
[`examples/dates.em`](../../examples/dates.em) for the programs below and more.

| Type | Meaning | Prints as | Page |
| --- | --- | --- | --- |
| `Date` | A day on the calendar: a birthday, a due date | `2026-09-25` | [Date](date.md) |
| `Time` | A time on the clock: an alarm, opening hours | `14:30:00` | [Time](time.md) |
| `DateTime` | A date and a time together, with no zone: what a calendar and wall clock show | `2026-09-25T14:30:00` | [DateTime](date-time.md) |
| `Instant` | An exact moment, the same everywhere: a timestamp, a deadline | `2026-09-25T18:30:00Z` | [Instant](instant.md) |
| `Duration` | An exact length of time: a timeout, a stopwatch reading | `1h 30m` | [Duration](duration.md) |
| `TimeZone` | Where the clocks are: `UTC`, `+05:30`, `America/New_York`, or the machine's | `Europe/Paris` | [TimeZone](time-zone.md) |
| `Stopwatch` | Measures how long something takes | | [Stopwatch](stopwatch.md) |

`Weekday` (`Monday` through `Sunday`) is described with [`Date`](date.md), and
`Program.sleep(duration)` with [`Program`](program.md).

```emerald
const today = Date.today()
var birthday = Date(today.year, 3, 14)
if birthday < today {
    birthday = birthday.add(years: 1)
}
print("#{today.days_until(birthday)} days to go")
```

## Operators for exact time, words for the calendar

`Duration` and `Instant` have operators, because their arithmetic is exact: an `Instant` plus
a `Duration` is always the same moment. A step on the calendar depends on where it starts,
so it is a method with named units: `date.add(months: 1)` from 31 January lands on the last
day of February. The units are always named, because `Duration(5)` would otherwise mean five
days without saying so; it is an error that lists the units.

A calendar day and 24 hours usually agree, but not on a day the clocks change. Adding
`days: 1` to a `DateTime` keeps the time on the clock; adding `Duration(days: 1)` to an
`Instant` keeps exactly 24 hours.

## Text

Every value prints in the ISO 8601 form above, which reads the same in every country and
sorts correctly as text, and each type's `parse` reads that form back. `parse_maybe` returns
`nothing` instead of raising. Other layouts come from interpolating the parts:

```emerald
const day = Date(2026, 9, 25)
print("#{day.weekday}, #{day.month_name} #{day.day}, #{day.year}")   # Friday, September 25, 2026
```

## Time zones

A function that needs a zone takes a `zone` argument, which defaults to `TimeZone.local`, the
machine's own. `emerald check`, tests of Emerald itself, and embedded runs use UTC instead,
so they never depend on the machine. Named zones come from a copy of the IANA time zone
database built into Emerald, so a program gives the same answer on every operating system.

## Errors

A value that cannot exist, text in the wrong form, or an unknown zone raises
`DateTimeError`, a `RuntimeError` whose message names the part that is wrong and its range:

```text
DateTimeError: day 30 is not between 1 and 28: February 2026 has 28 days
```
