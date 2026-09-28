# CsvError retains the physical line when one is known, and every public
# untyped failure is catchable as that one error type.
try {
    Csv.parse("name\n\"Ada")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}

try {
    Csv.parse("name\n\"Ada\"x")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}

try {
    Csv.parse("name", separator: ";;")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}

try {
    Csv.parse_records("name,score\nAda")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}

try {
    Csv.parse_records("name,name\nAda,Grace")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}

try {
    Csv.parse_records("\nAda")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}
