# Section 11.2: `Trait.method(value)` may run a default that changes the value only on
# an object for now; on a struct it is rejected.
trait Counter {
    var count: Int

    func bump() {
        self.count += 1
    }
}

struct Tally with Counter {
    var count: Int = 0
}

class Clicker with Counter {
    var count: Int = 0
}

var tally = Tally()
Counter.bump(tally)
const clicker = Clicker()
Counter.bump(clicker)
