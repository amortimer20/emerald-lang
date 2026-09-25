# DateTime

A `DateTime` is a date and a time of day together, with no time zone: what a calendar and a
wall clock show. A timetable entry, a meeting in the local diary, or a log line written in
local time is a `DateTime`. It is an immutable value that compares, orders, and can be a
dictionary key. Run
[`conformance/run/date-time-basics.em`](../../conformance/run/date-time-basics.em) for every
case below, and [`conformance/local-zone/clock-changes.em`](../../conformance/local-zone/clock-changes.em)
for what happens when clocks change.

## DateTime(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) -> DateTime

`DateTime(2026, 9, 25, 14, 30)` is 25 September 2026 at 14:30. `date.at(time)` builds one
from a [`Date`](date.md) and a [`Time`](time.md).

**Raises** `DateTimeError` for any part out of range, as `Date` and `Time` do.

## DateTime.now(zone: TimeZone = TimeZone.local) -> DateTime

What a calendar and clock in `zone` show now.

## DateTime.parse(text: String) -> DateTime

Reads a date and a time separated by `T` or one space: `2026-09-25T14:30:00`,
`2026-09-25 14:30`. The time may leave out its seconds and may have a fraction, as
`Time.parse` allows.

**Raises** `DateTimeError` for any other layout or a part out of range.

## DateTime.parse_maybe(text: String) -> DateTime?

`DateTime.parse`, returning `nothing` instead of raising.

## date -> Date, time -> Time

The two halves.

## year, month, day, hour, minute, second, nanosecond -> Int, weekday -> Weekday

The parts of the two halves, read directly.

## add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0) -> DateTime

A later date and time. Every amount must be named. Years and months move the date as
`Date.add` does; then weeks, days, and any whole days the time units carried past midnight.
So `DateTime(2026, 1, 31, 23).add(months: 1, hours: 2)` is `2026-03-01T01:00:00`.

**Raises** `DateTimeError` when the result would fall outside the years 1 through 9999.

## subtract(years: Int = 0, ..., nanoseconds: Int = 0) -> DateTime

`add` with every amount negated.

## duration_until(other: DateTime) -> Duration

The difference the calendar and clock show, as if every day had exactly 24 hours:
`DateTime(2026, 9, 25, 14, 30).duration_until(DateTime(2026, 12, 25))` is `90d 9h 30m`. A
`DateTime` has no zone, so it cannot know that clocks changed in between; for an exact
difference, convert both with `to_instant` and subtract.

## to_instant(zone: TimeZone = TimeZone.local) -> Instant

The moment this date and time is in `zone`.

Twice a year, many zones change their clocks. When clocks go back, a time such as 01:30
happens twice, and `to_instant` gives the earlier moment. When clocks go forward, a time such
as 02:30 never happens, and `to_instant` moves it forward by the length of the gap: in New
York, `DateTime(2026, 3, 8, 2, 30).to_instant()` is 03:30 daylight time. It never raises for
either.

## Display

`YYYY-MM-DDTHH:MM:SS`, with a fraction of a second only when there is one.
