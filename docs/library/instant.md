# Instant

An `Instant` is an exact moment, the same everywhere in the world: when a message was sent,
when an order was placed, a deadline. It counts nanoseconds from 1970-01-01T00:00:00 UTC,
from the start of year 1 to the end of 9999. It is an immutable value that compares, orders,
and can be a dictionary key. Run
[`conformance/run/instant-basics.em`](../../conformance/run/instant-basics.em) for every case
below.

## Instant.now() -> Instant

The moment now, from the system clock. For measuring how long something takes, use a
[`Stopwatch`](stopwatch.md), which a change to the system clock cannot disturb.

## Instant.from_unix_seconds(seconds: Int) -> Instant

## Instant.from_unix_milliseconds(milliseconds: Int) -> Instant

The moment a Unix timestamp names, as other systems and file formats often store one.

**Raises** `DateTimeError` for a moment outside the years 1 through 9999.

## Instant.parse(text: String) -> Instant

Reads a date and time followed by `Z` for UTC or an offset: `2026-09-25T14:30:00Z`,
`2026-09-25T14:30:00+02:00`. This is RFC 3339, the form most web services use.

**Raises** `DateTimeError` for any other layout. Text without `Z` or an offset could be any
moment, so it gets its own message suggesting `Z`, or `DateTime.parse` instead.

## Instant.parse_maybe(text: String) -> Instant?

`Instant.parse`, returning `nothing` instead of raising.

## unix_seconds, unix_milliseconds -> Int

The Unix timestamp, rounded toward the past as Unix time is.

## instant + duration -> Instant, instant - duration -> Instant

A later or earlier moment, exactly `duration` away. The methods are `after(duration)` and
`before(duration)`.

**Raises** `DateTimeError` for a moment outside the years 1 through 9999.

## instant - other -> Duration

The exact time from `other` to this moment, negative when `other` is later. The method is
`since(other)`.

## to_date_time(zone: TimeZone = TimeZone.local) -> DateTime

What a calendar and clock in `zone` show at this moment:

```emerald
const meeting = DateTime(2026, 10, 1, 9).to_instant(TimeZone("America/New_York"))
print(meeting.to_date_time(TimeZone("Europe/Paris")))   # 2026-10-01T15:00:00
```

## Display

Always in UTC, marked with `Z`: `2026-10-01T13:00:00Z`. Use `to_date_time` for local time.
