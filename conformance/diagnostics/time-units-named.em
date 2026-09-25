# Section 15.8: an amount of time must say which unit it is in.
print(Duration(5))
print(Date(2026, 1, 1).add(1))
print(Date(2026, 1, 1).subtract(years: 1))
print(Time(9).add(1))
print(DateTime(2026, 1, 1).subtract(2))
print(Time(9).add(hours: 1), DateTime(2026, 1, 1).add(days: 1))
print(Duration(seconds: 5), Emerald.Duration(minutes: 1))
