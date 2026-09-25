# Section 15.8's Instant: an exact moment, the same everywhere.
const moment = Instant.from_unix_seconds(1790000000)
print(moment, moment.unix_seconds, moment.unix_milliseconds)
print(Instant.from_unix_seconds(0), Instant.from_unix_milliseconds(-1))

# Operators do exact arithmetic: Instant +/- Duration, and Instant - Instant.
print(moment + Duration(hours: 1), moment - Duration(days: 1))
print(moment - Instant.from_unix_seconds(0), moment + Duration(milliseconds: 1500) - moment)

# A zone turns a moment into what a calendar and clock show there, and back.
print(moment.to_date_time(TimeZone.utc), moment.to_date_time(TimeZone.fixed(hours: 5, minutes: 30)))
print(moment.to_date_time(TimeZone("-03:30")))
const meeting = DateTime(2026, 10, 1, 9).to_instant(TimeZone.fixed(hours: -4))
print(meeting, meeting.to_date_time(TimeZone.fixed(hours: 2)))

# RFC 3339 text: Z or an offset is required, and what an Instant prints reads back.
print(Instant.parse("2026-09-25T14:30:00Z"), Instant.parse("2026-09-25T14:30:00.5+02:00"))
print(Instant.parse("2026-09-25 00:00-00:30"), Instant.parse(moment.to_string()) == moment)
print(Instant.parse_maybe("2026-09-25T14:30:00"), Instant.parse_maybe("2026-09-25T14:30:00+19:00"))

# Values: ordered, compared, and usable as dictionary keys.
print(moment < moment + Duration(nanoseconds: 1), [moment: "m"][Instant.parse("2026-09-21T14:13:20Z")])

# The range is the years 1 through 9999, to the nanosecond.
print(Instant.from_unix_seconds(-62135596800), Instant.from_unix_seconds(253402300799) + Duration(nanoseconds: 999999999))

# TimeZone: UTC and fixed offsets, named and displayed like "+05:30".
print(TimeZone.utc, TimeZone.fixed(hours: -3, minutes: -30), TimeZone.fixed(hours: 0), TimeZone("+05:30"))
print(TimeZone("UTC") == TimeZone.utc, TimeZone.fixed(hours: 0) == TimeZone.utc, TimeZone.fixed(hours: 5).offset_at(moment))
