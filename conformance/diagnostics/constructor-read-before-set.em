struct Range {
    var low: Int
    var high: Int

    constructor(size: Int) {
        self.high = self.low + size
        self.low = 0
    }
}

print(Range(3))
