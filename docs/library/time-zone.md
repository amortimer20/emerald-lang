# TimeZone

A `TimeZone` says where the clocks are, and so turns an [`Instant`](instant.md) into what a
calendar and clock show there. Two zones are equal when their names are, and a zone can be a
dictionary key. Run
[`conformance/run/named-zones.em`](../../conformance/run/named-zones.em) for named zones and
[`conformance/run/instant-basics.em`](../../conformance/run/instant-basics.em) for UTC and
fixed offsets.

## TimeZone(name: String) -> TimeZone

Any zone in the IANA time zone database, such as `"America/New_York"`, `"Europe/Paris"`, or
`"Asia/Kolkata"`, with its whole history: New York kept its own local mean time until 1883,
and Brazil stopped daylight time in 2019. Older names such as `"US/Eastern"` work too. A copy
of the database is built into Emerald, so a zone gives the same answer on every operating
system. `"UTC"` and an offset such as `"+05:30"` are names too.

Names are case-sensitive, as IANA's are.

**Raises** `DateTimeError` for an unknown name. A name in the wrong case is refused with the
right spelling: `zone names are case-sensitive, so write "America/New_York"`.

## TimeZone.named_maybe(name: String) -> TimeZone?

`TimeZone(name)`, returning `nothing` for an unknown name instead of raising.

## TimeZone.utc -> TimeZone

Coordinated Universal Time, named `UTC`.

## TimeZone.local -> TimeZone

The machine's own zone, decided once when the program starts, and the default wherever a
zone is optional. `emerald run`, `test`, and `repl` read it the way the C library does: from
the `TZ` environment variable if it is set, otherwise `/etc/localtime`; on Windows, from the
system's settings. Anything that cannot be read leaves the program in UTC rather than
stopping it. `emerald check`, tests of Emerald itself, and embedded runs always use UTC.

## TimeZone.fixed(hours: Int, minutes: Int = 0) -> TimeZone

A zone always this far ahead of UTC, named like its offset: `TimeZone.fixed(hours: 5,
minutes: 30)` is `+05:30`. The minutes take the sign of the hours, so `-03:30` is
`TimeZone.fixed(hours: -3, minutes: -30)`. It is not the same zone as a place that happens to
share its offset today, since a place can change its clocks.

**Raises** `DateTimeError` for minutes with the wrong sign or beyond 59, or an offset beyond
18 hours.

## name -> String

The zone's name, which is also how it prints.

## offset_at(instant: Instant) -> Duration

How far ahead of UTC the zone's clocks are at `instant`:
`TimeZone("America/New_York")` gives `-5h` in January and `-4h` in July.
