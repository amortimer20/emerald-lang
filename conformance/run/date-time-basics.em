# Section 15.8's DateTime: a date and time of day with no zone.
const launch = DateTime(2026, 9, 25, 14, 30)
print(launch, launch.date, launch.time, launch.weekday, DateTime(2026, 1, 1))
print(launch.year, launch.month, launch.day, launch.hour, launch.minute, launch.second, launch.nanosecond)
print(Date(2026, 9, 25).at(Time(9)), Date(2026, 9, 25).at(Time(14, 30)) == launch)

# Calendar units move the date as Date.add does; time units carry whole days
# past midnight into it.
print(launch.add(hours: 10), launch.subtract(minutes: 871), launch.add(months: 5, days: 6))
print(DateTime(2026, 1, 31, 23).add(months: 1, hours: 2))
print(DateTime(2026, 9, 25, 1, 2, 3, 500).add(nanoseconds: -1000))
print(DateTime(9999, 12, 31, 23, 59).subtract(years: 9998, months: 11, days: 30, hours: 23, minutes: 59))

# The wall-clock difference, as if every day had 24 hours.
const party = DateTime(2026, 12, 25)
print(launch.duration_until(party), party.duration_until(launch), launch.duration_until(launch))

# Values: ordered, compared, and usable as dictionary keys.
print(launch < DateTime(2026, 9, 25, 14, 31), [party, launch].sort(), [launch: "go"][DateTime(2026, 9, 25, 14, 30)])

# ISO 8601 text, with T or one space between the date and the time.
print(DateTime.parse("2026-09-25T14:30:00") == launch, DateTime.parse("2026-09-25 14:30:00.5"))
print(DateTime.parse(launch.to_string()) == launch)
print(DateTime.parse_maybe("2026-09-25"), DateTime.parse_maybe("2026-09-25T25:00"), DateTime.parse_maybe("2026-09-25t14:30"))

# A log line, as a beginner writes one.
print("[#{launch.date} #{launch.time}] started")
