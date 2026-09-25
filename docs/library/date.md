# Date

A `Date` is a day on the calendar, with no time of day or time zone: a birthday, a due date,
a holiday. It uses the Gregorian calendar, extended back before 1582 as ISO 8601 does, from
year 1 through 9999. A `Date` is an immutable value: equal dates compare equal, dates order
from earlier to later, and a date can be a dictionary key. See
[Dates and times](dates-and-times.md) for choosing between the date and time types, and run
[`conformance/run/date-basics.em`](../../conformance/run/date-basics.em) for every case below.

## Date(year: Int, month: Int, day: Int) -> Date

Months are numbered 1 through 12. `Date(2026, 9, 25)` is 25 September 2026.

**Raises** `DateTimeError` for a year outside 1–9999, a month outside 1–12, or a day the
month does not have: `day 30 is not between 1 and 28: February 2026 has 28 days`.

## Date.today(zone: TimeZone = TimeZone.local) -> Date

Today's date in `zone`.

## Date.parse(text: String) -> Date

Reads `YYYY-MM-DD`, such as `2026-09-25`, ignoring spaces around it. It is the form a `Date`
prints as, so `Date.parse(date.to_string()) == date`.

**Raises** `DateTimeError` for any other layout, naming the expected one, or for a date that
cannot exist.

## Date.parse_maybe(text: String) -> Date?

`Date.parse`, returning `nothing` instead of raising. `.or(fallback)` supplies a default.

## year, month, day -> Int

The parts of the date, each read-only.

## weekday -> Weekday

The day of the week: `Date(1969, 7, 20).weekday` is `Weekday.sunday`, which prints as
`Sunday`. `Weekday` lists `monday` through `sunday`, Monday first as in ISO 8601. It has no
order and no number: the week is a cycle, and whether Sunday or Monday comes first, or counts
as 0 or 1, differs between countries and programs. Compare it with `==` or use it in `case`.

## month_name -> String

The month's English name, such as `"September"`, for building text.

## day_of_year -> Int

1 for 1 January, up to 365, or 366 in a leap year.

## days_in_month -> Int

28, 29, 30, or 31.

## leap_year?() -> Bool

Whether the date's year has a 29 February: every fourth year, except century years not
divisible by 400. 2000 was a leap year; 1900 was not.

## add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0) -> Date

A later date, or an earlier one for negative amounts. Every amount must be named: `add(1)` is
a checking error, since it would silently mean one year.

Years and months move first. The day stays the same when the new month has it, and otherwise
becomes that month's last day, so `Date(2026, 1, 31).add(months: 1)` is `2026-02-28` and
`Date(2024, 2, 29).add(years: 1)` is `2025-02-28`. Weeks and days then count calendar days.

**Raises** `DateTimeError` when the result would fall outside the years 1 through 9999.

## subtract(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0) -> Date

`add` with every amount negated.

## days_until(other: Date) -> Int

The number of days from this date to `other`, negative when `other` is earlier.

## months_until(other: Date) -> Int

Whole months from this date to `other`: the most that `add(months:)` can move this date
without passing `other`. 31 January to 28 February is one month.

## years_until(other: Date) -> Int

Whole years, so `born.years_until(Date.today())` is an age. Someone born on 29 February has
a birthday on 28 February in other years.

## at(time: Time) -> DateTime

This date at a time of day: `Date(2026, 9, 25).at(Time(9))` is `2026-09-25T09:00:00`.
