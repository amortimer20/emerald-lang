# Section 4.3: `const` stops at the first reference. A `const` field of an
# object still cannot change, and neither can what a `const` field holds when
# it is a value; a `const` struct holding an object can still change the
# object.
class Account {
    const id: Int
    var balance: Int = 0
    const home: Point = Point(0)
}

struct Point {
    var x: Int
}

class Other {
}

struct Box {
    const account: Account
    var count: Int = 0
}

const a = Account(1)
a.id = 2
a.home.x = 3
const b = Box(a)
b.count = 1
b.account.balance = 5
var keyed: [Account: Int] = []
print(a == Other())
