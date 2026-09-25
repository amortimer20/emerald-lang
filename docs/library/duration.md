# Duration

A `Duration` is an exact length of time, to the nanosecond: a timeout, a lap time, how long
until lunch. It may be negative. A day in a `Duration` is exactly 24 hours, unlike a day on
the calendar, which is 23 or 25 hours when clocks change. It is an immutable value that
compares, orders, and can be a dictionary key. Run
[`conformance/run/duration-basics.em`](../../conformance/run/duration-basics.em) for every
case below.

## Duration(days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0) -> Duration

Any combination of units, added together: `Duration(hours: 1, minutes: 30)`. Every amount
must be named, so `Duration(5)` is a checking error that lists the units; by position it
would silently mean five days. `Duration()` is zero.

## duration + other, duration - other -> Duration

The sum or difference of two lengths. `+=` and `-=` work too.

## duration * factor, duration / divisor -> Duration

A length multiplied or divided by an `Int`. Division rounds toward zero, to the nanosecond:
`Duration(seconds: 1) / 3` is `0.333333333s`.

**Raises** `DateTimeError` for a divisor of zero.

## duration / other -> Float

How many times `other` fits into this length: `Duration(hours: 1, minutes: 30) /
Duration(minutes: 45)` is `2.0`.

**Raises** `DateTimeError` when `other` is zero.

## total_days, total_hours, total_minutes, total_seconds, total_milliseconds -> Float

The whole length in one unit, with a fraction: `Duration(minutes: 90).total_hours` is `1.5`.

## whole_days, whole_hours, whole_minutes, whole_seconds, whole_milliseconds, whole_microseconds, whole_nanoseconds -> Int

The whole length in one unit, rounded toward zero: `Duration(minutes: 90).whole_hours` is
`1`, and `whole_minutes` is `90`.

## abs() -> Duration, zero?() -> Bool, negative?() -> Bool

The length without its sign, and whether it is zero or negative.

## Display

The units that are not zero, largest first: `2d 3h`, `1h 30m`, `45s`. A fraction of a second
shows as decimal seconds (`1.25s`), zero is `0s`, and a negative length starts with `-`.
