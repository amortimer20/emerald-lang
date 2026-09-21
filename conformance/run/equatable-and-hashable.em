# Section 8.4's `Equatable`/`Hashable`: a type that adopts `Equatable` compares
# through its own `equals()` in place of the default (structural for a struct,
# identity for a class); `!=` always follows as `not equals(other)`.

class Money with Equatable {
    var cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }

    @override
    func equals(other: Money): Bool {
        return self.cents == other.cents
    }
}

const price = Money(500)
const same_price = Money(500)
const other_price = Money(199)
print(price == same_price, price != same_price)
print(price == other_price, price != other_price)

# A plain class keeps identity: two different instances with the same fields
# are not equal, unlike `Money` above.
class Plain {
    var cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }
}
print(Plain(500) == Plain(500))

# `Hashable` (which requires `Equatable`, section 11.2's trait composition)
# is what makes a struct a dictionary or set key through its own `equals()`
# and `hash()`, rather than the structural default. Two texts differing only
# in case collapse to one entry.
struct CaseInsensitive with Hashable {
    var text: String

    @override
    func equals(other: CaseInsensitive): Bool {
        return self.text.lower() == other.text.lower()
    }

    @override
    func hash(): Int {
        return self.text.lower().count
    }
}

const words: Set[CaseInsensitive] = [
    CaseInsensitive("Hello"),
    CaseInsensitive("HELLO"),
    CaseInsensitive("World"),
]
print(words.count)
print(words.contains?(CaseInsensitive("hello")))

var counts: Dict[CaseInsensitive, Int] = []
for word in ["Ada", "ada", "ADA", "Bea"] {
    const key = CaseInsensitive(word)
    counts[key] = counts[key].or(0) + 1
}
print(counts.count)

# Adopting types compare the same nested inside a collection as they do
# alone, the same way `Textual`'s display reaches every nesting.
const first: List[Money] = [Money(1), Money(2)]
const second: List[Money] = [Money(1), Money(2)]
print(first == second)
print((Money(1), "left") == (Money(1), "left"))

# A trait that builds on `Hashable` carries the adoption with it, the same
# way one built on `Textual` does.
trait Priced with Hashable {
    func describe(): String
}

struct Ticket with Priced {
    var id: Int

    @override
    func equals(other: Ticket): Bool {
        return self.id == other.id
    }

    @override
    func hash(): Int {
        return self.id
    }

    @override
    func describe(): String {
        return "ticket ##{self.id}"
    }
}
const sold: Set[Ticket] = [Ticket(1), Ticket(1), Ticket(2)]
print(sold.count, Ticket(1).describe())

# An `equals()` that raises propagates like any other call, and nothing of
# the interrupted comparison reaches its result.
struct Unreliable with Hashable {
    var value: Int

    @override
    func equals(other: Unreliable): Bool {
        if other.value < 0 {
            raise RuntimeError("cannot compare a negative value")
        }
        return self.value == other.value
    }

    @override
    func hash(): Int {
        return self.value
    }
}

try {
    print("never reached", Unreliable(1) == Unreliable(-1))
}
catch error: RuntimeError {
    print("caught #{error.message}")
}
