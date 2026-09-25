# Time

A `Time` is a time on the clock, with no date or time zone: an alarm, a shop's opening hours,
the start of a class. It counts to the nanosecond. Like the other date and time types, it is
an immutable value that compares, orders, and can be a dictionary key. Run
[`conformance/run/time-basics.em`](../../conformance/run/time-basics.em) for every case below.

## Time(hour: Int, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) -> Time

Hours run from 0 to 23. `Time(7, 30)` is half past seven in the morning; `Time(19, 30)` is
half past seven in the evening.

**Raises** `DateTimeError` for a part out of its range: `hour 24 is not between 0 and 23`.

## Time.now(zone: TimeZone = TimeZone.local) -> Time

The time on the clock in `zone` now.

## Time.parse(text: String) -> Time

Reads `HH:MM`, `HH:MM:SS`, or `HH:MM:SS` followed by a fraction of a second with one to nine
digits: `14:30`, `14:30:05`, `14:30:05.25`. Spaces around it are ignored.

**Raises** `DateTimeError` for any other layout or a part out of range.

## Time.parse_maybe(text: String) -> Time?

`Time.parse`, returning `nothing` instead of raising.

## hour, minute, second, nanosecond -> Int

The parts of the time, each read-only.

## add(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0) -> Time

A later time, wrapping around midnight as a clock does: `Time(23, 0).add(hours: 2)` is
`01:00:00`. Every amount must be named. A program that needs to know the day changed uses a
[`DateTime`](date-time.md) instead.

## subtract(hours: Int = 0, ..., nanoseconds: Int = 0) -> Time

`add` with every amount negated, also wrapping: `Time(0, 15).subtract(minutes: 30)` is
`23:45:00`.

## Display

`HH:MM:SS`, with a fraction of a second only when there is one, in groups of three digits:
`14:30:00`, `14:30:00.250`, `01:02:03.000004`.
