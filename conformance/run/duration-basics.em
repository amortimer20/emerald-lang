# Section 15.8's Duration: an exact length of time, to the nanosecond.
const trip = Duration(hours: 1, minutes: 30)
print(trip, Duration(), Duration(days: 2, hours: 3), Duration(milliseconds: 1250))
print(Duration(minutes: -5), Duration(nanoseconds: 1), Duration(microseconds: 2500))
print(trip.total_minutes, trip.total_hours, trip.total_days, Duration(milliseconds: 1250).total_milliseconds)
print(trip.total_seconds, trip.zero?(), Duration().zero?(), Duration(seconds: -1).negative?())

# Whole units round toward zero.
print(trip.whole_hours, Duration(minutes: -90).whole_hours, Duration(milliseconds: 1999).whole_seconds)
print(Duration(seconds: 2).whole_milliseconds, Duration(days: 3).whole_minutes, Duration(days: 2).whole_days)
print(Duration(nanoseconds: -1500).whole_microseconds, Duration(milliseconds: 5).whole_nanoseconds)

# Operators do exact arithmetic.
print(trip + Duration(minutes: 5), trip - Duration(hours: 2), trip * 3, trip / 4)
print(trip / Duration(minutes: 45), Duration(seconds: 59, milliseconds: 999) + Duration(milliseconds: 1))
var total = Duration()
total += Duration(minutes: 20)
total *= 2
print(total)

# Division by a whole number rounds toward zero, to the nanosecond, even when
# the divisor is too large to scale directly.
print(Duration(seconds: 1) / 3, Duration(seconds: -1) / 3, Duration(seconds: 10) / -4)
print(Duration(days: 3000000) / 20000000000, Duration(seconds: 7) / 10000000000)
print(Duration(seconds: 12345678901, nanoseconds: 999999999) / 12345678902)
print(Duration(days: 3000000) / 20000000000 * 20000000000)

# Negative lengths print with a sign; abs removes it.
print(Duration(seconds: 1) * -1, Duration(milliseconds: -1500), (Duration(seconds: -1) / 3).abs())

# Values: ordered, compared, and usable as dictionary keys.
print(trip > Duration(hours: 1), [Duration(minutes: 3), Duration(seconds: 5)].sort())
print(trip == Duration(minutes: 90), [trip: "trip"][Duration(seconds: 5400)])
