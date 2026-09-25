# Section 15.8's DateTimeError names the part that is wrong and its range.
func attempt(label: String, block: func(): Date) {
    try {
        print(label, block())
    }
    catch error: DateTimeError {
        print(label, error.message)
    }
}

attempt("month") { => Date(2026, 13, 1) }
attempt("year") { => Date(0, 1, 1) }
attempt("leap") { => Date(2026, 2, 29) }
attempt("parse range") { => Date.parse("2026-13-01") }
attempt("parse shape") { => Date.parse("25/09/2026") }
attempt("past 9999") { => Date(9999, 12, 31).add(days: 1) }
attempt("month past 9999") { => Date(9999, 12, 1).add(months: 1) }
attempt("date and time") { => DateTime(2026, 2, 30, 10).date }
attempt("hour past 9999") { => DateTime(9999, 12, 31, 23).add(hours: 1).date }

func attempt_time(label: String, block: func(): Time) {
    try {
        print(label, block())
    }
    catch error: DateTimeError {
        print(label, error.message)
    }
}

attempt_time("hour") { => Time(24) }
attempt_time("minute") { => Time(12, 60) }
attempt_time("nanosecond") { => Time(9, 0, 0, -1) }
attempt_time("parse shape") { => Time.parse("7:30") }
attempt_time("parse range") { => Time.parse("12:61") }
attempt_time("date and time text") { => DateTime.parse("2026-09-25T24:00").time }
attempt_time("date and time shape") { => DateTime.parse("2026-09-25").time }

try {
    print(Duration(seconds: 1) / 0)
}
catch error: DateTimeError {
    print(error.message)
}

try {
    print(Duration(seconds: 1) / Duration())
}
catch error: RuntimeError {
    print(error.type_name, error.message)
}

func attempt_moment(label: String, block: func(): Instant) {
    try {
        print(label, block())
    }
    catch error: DateTimeError {
        print(label, error.message)
    }
}

attempt_moment("after 9999") { => Instant.from_unix_seconds(253402300800) }
attempt_moment("before 1") { => Instant.from_unix_seconds(-62135596800) - Duration(nanoseconds: 1) }
attempt_moment("no offset") { => Instant.parse("2026-09-25T14:30:00") }
attempt_moment("moment shape") { => Instant.parse("2026-09-25T14:30Q") }
attempt_moment("moment range") { => Instant.parse("2026-09-25T14:61:00Z") }
attempt_moment("zone name") { => DateTime(2026, 1, 1).to_instant(TimeZone("Mars/Olympus")) }
attempt_moment("minute sign") { => DateTime(2026, 1, 1).to_instant(TimeZone.fixed(hours: -3, minutes: 30)) }
attempt_moment("offset size") { => DateTime(2026, 1, 1).to_instant(TimeZone.fixed(hours: 19)) }

try {
    Program.sleep(Duration(seconds: -1))
}
catch error: DateTimeError {
    print(error.message)
}
