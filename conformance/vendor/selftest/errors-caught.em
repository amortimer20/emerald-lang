# A native's failure is an ordinary typed error that a program can catch.
try {
    Selftest.fails()
}
catch error: SelftestError {
    print("caught: #{error.message}")
}

const counter = Selftest.counter()
counter.close()
try {
    counter.next()
}
catch error: Error {
    print("also an Error: #{error.message}")
}
print(Selftest.open_count())
