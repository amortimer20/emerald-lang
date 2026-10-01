trait Counter {
    var count: Int

    func bump(amount: Int) {
        self.count += amount
    }
}

class Tally with Counter {
    var count: Int = 0
}

const tally = Tally()
Counter.bump(tally, amount: 5)
assert tally.count == 5
print(tally.count)
