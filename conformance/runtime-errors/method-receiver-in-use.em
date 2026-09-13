struct Meter {
    var reading: Int

    func advance() {
        self.reading += 1
        report()
    }
}

var meter = Meter(0)

# `meter` is taken by `advance` while it runs, so reaching it by name from
# inside that call is an error rather than a look at a half-changed value.
func report() {
    print(meter)
}

meter.advance()
