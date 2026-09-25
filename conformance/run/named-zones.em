# Section 15.8's named zones, from the IANA database built into Emerald, so
# every machine gives the same answers.
const new_york = TimeZone("America/New_York")
const meeting = DateTime(2026, 10, 1, 9).to_instant(new_york)
print(meeting, meeting.to_date_time(TimeZone("Europe/Paris")), meeting.to_date_time(TimeZone("Asia/Tokyo")))
print(meeting.to_date_time(TimeZone("Asia/Kolkata")), meeting.to_date_time(TimeZone("Australia/Sydney")))

# Clock changes: a skipped time moves forward, and a repeated time is the
# earlier moment.
print(DateTime(2026, 3, 8, 2, 30).to_instant(new_york), DateTime(2026, 11, 1, 1, 30).to_instant(new_york))
print(new_york.offset_at(Instant.parse("2026-01-15T12:00:00Z")), new_york.offset_at(Instant.parse("2026-07-15T12:00:00Z")))

# History: Brazil stopped daylight time in 2019, and New York kept its own
# local mean time until 1883. The rules also run on past the last recorded
# change.
const sao_paulo = TimeZone("America/Sao_Paulo")
print(sao_paulo.offset_at(Instant.parse("2019-01-15T00:00:00Z")), sao_paulo.offset_at(Instant.parse("2020-01-15T00:00:00Z")))
print(Instant.parse("1850-01-01T00:00:00Z").to_date_time(new_york), DateTime(2300, 7, 1, 12).to_instant(new_york))

# Every name IANA has, including older aliases and Etc zones, whose sign is
# the reverse of how an offset is written.
print(TimeZone("US/Eastern").offset_at(meeting), TimeZone("Etc/GMT+5").offset_at(meeting), TimeZone("Etc/UTC"))

# A zone is a value: equal by name, and usable as a dictionary key.
print(new_york == TimeZone("America/New_York"), new_york == TimeZone("US/Eastern"), [new_york: "home"][TimeZone("America/New_York")])
print(TimeZone.named_maybe("Mars/Olympus"), TimeZone.named_maybe("Europe/London"), TimeZone.named_maybe("+02:00"))

func attempt(name: String) {
    try {
        print(TimeZone(name))
    }
    catch error: DateTimeError {
        print(error.message)
    }
}

attempt("america/new_york")
attempt("Mars/Olympus")
