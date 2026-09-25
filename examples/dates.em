# Dates and times: the programs a beginner most often wants to write.
# Run it with `emerald run examples/dates.em`; the first lines depend on today.

# How many days until a birthday?
const today = Date.today()
var birthday = Date(today.year, 3, 14)
if birthday < today {
    birthday = birthday.add(years: 1)
}
print("#{today.days_until(birthday)} days until the birthday on #{birthday}")

# How old is someone born on 2 June 2011?
const born = Date(2011, 6, 2)
print("Born #{born}, so #{born.years_until(today)} years old today")

# What day of the week was it?
print("The Moon landing was on a #{Date(1969, 7, 20).weekday}")

# A date written the way people read it.
const launch = Date(2026, 9, 25)
print("#{launch.weekday}, #{launch.month_name} #{launch.day}, #{launch.year}")

# Adding a month keeps the day when it can, and otherwise uses the last day.
print(Date(2026, 1, 31).add(months: 1))

# A length of time, and arithmetic with it.
const lunch = Duration(minutes: 45)
const trip = Duration(hours: 1, minutes: 30)
print("Back in #{lunch}; the trip takes #{trip}, or #{trip.whole_minutes} minutes")
print("Two trips: #{trip * 2}")

# How long did that take?
const watch = Stopwatch.start()
var total = 0
for number in 1..100000 {
    total += number
}
print("Added up to #{total} in #{watch.elapsed()}")

# A meeting at 9:00 in New York, as clocks in other cities show it.
const meeting = DateTime(2026, 10, 1, 9, 0).to_instant(TimeZone("America/New_York"))
for city in ["Europe/Paris", "Asia/Tokyo", "Asia/Kolkata"] {
    print("#{city}: #{meeting.to_date_time(TimeZone(city)).time}")
}

# Reading dates and times from text, and a friendly message when it fails.
print(DateTime.parse("2026-12-24T18:30"))
const typed = Date.parse_maybe("24/12/2026")
if typed == nothing {
    print("Write dates as YYYY-MM-DD, such as 2026-12-24")
}

# A countdown.
for count in 3.down_to(1) {
    print(count)
    Program.sleep(Duration(milliseconds: 200))
}
print("Go!")
