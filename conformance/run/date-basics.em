# Section 15.8's Date: a calendar date with no time of day or zone.
const today = Date(2026, 9, 25)
print(today, today.weekday, today.month_name, today.day_of_year, today.days_in_month)
print(today.year, today.month, today.day, today.leap_year?())

# The proleptic Gregorian calendar, from year 1 through 9999.
print(Date(1969, 7, 20).weekday, Date(1970, 1, 1).weekday, Date(1, 1, 1).weekday)
print(Date(1900, 2, 28).add(days: 1), Date(2000, 2, 28).add(days: 1), Date(9999, 12, 31))
print(Date(1900, 1, 1).leap_year?(), Date(2000, 1, 1).leap_year?(), Date(2024, 12, 31).day_of_year)

# Months and years keep the day when they can, and otherwise use the month's
# last day; weeks and days count calendar days.
print(Date(2026, 1, 31).add(months: 1), Date(2024, 2, 29).add(years: 1), Date(2024, 2, 29).add(years: 4))
print(today.add(days: 100), today.subtract(weeks: 2), today.add(years: -1, days: 7))

# Differences count whole units, so years_until is an age.
print(Date(2026, 1, 1).days_until(Date(2027, 1, 1)), today.days_until(Date(2026, 3, 14)))
print(Date(2011, 6, 2).years_until(today), today.years_until(Date(2011, 6, 2)), today.months_until(today))
print(Date(2026, 1, 31).months_until(Date(2026, 2, 28)), Date(2026, 3, 31).months_until(Date(2026, 2, 28)))
print(Date(2008, 2, 29).years_until(Date(2009, 2, 28)))

# How many days until a birthday, as a beginner writes it.
var birthday = Date(today.year, 3, 14)
if birthday < today {
    birthday = birthday.add(years: 1)
}
print("#{today.days_until(birthday)} days to go")

# Values: ordered, compared, and usable as dictionary keys.
print(Date(2026, 3, 14) < today, [Date(2026, 3, 1), Date(2025, 1, 1)].sort(), Date(2026, 9, 25) == today)
const events = [today: "launch"]
print(events[Date.parse("2026-09-25")])

# ISO 8601 text reads back to an equal value.
print(Date.parse(" 2026-09-25 "), Date.parse(today.to_string()) == today)
print(Date.parse_maybe("2026-9-25"), Date.parse_maybe("2026-02-30"), Date.parse_maybe("25/09/2026"))

# Custom layouts come from interpolation.
print("#{today.weekday}, #{today.month_name} #{today.day}, #{today.year}")
