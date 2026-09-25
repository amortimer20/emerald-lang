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
