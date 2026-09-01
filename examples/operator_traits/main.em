# Operator overloading: an operator is a method reached through a trait (§3.2)
#
# There is no separate operator syntax to learn. `a + b` calls `a.add(b)`, so the
# thing you write is an ordinary method — and it stays discoverable by typing a dot.

struct Money with Addable, Subtractable, Multipliable, Equatable, Ordered {
    var cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }

    func add(other: Money): Money {                # a + b
        return Money(self.cents + other.cents)
    }

    func subtract(other: Money): Money {           # a - b
        return Money(self.cents - other.cents)
    }

    func multiply(times: Int): Money {             # a * 3 — the right side need not
        return Money(self.cents * times)           # be a Money
    }

    func equals?(other: Money): Bool {             # a == b, and a != b as its negation
        return self.cents == other.cents
    }

    func compare(other: Money): Int {              # <, >, <=, >= all read this
        return self.cents - other.cents            # negative, zero, or positive
    }

    func to_string(): String {
        var whole = self.cents // 100
        var part = self.cents % 100
        var pennies = if part < 10 then "0#{part}" else "#{part}"
        return "$#{whole}.#{pennies}"
    }
}

var lunch = Money(1250)
var coffee = Money(450)

print("lunch      #{lunch.to_string()}")
print("coffee     #{coffee.to_string()}")
print("together   #{(lunch + coffee).to_string()}")
print("difference #{(lunch - coffee).to_string()}")
print("three teas #{(coffee * 3).to_string()}")

# One compare method answers all four ordering operators.
print("dearer?    #{lunch > coffee}")
print("same?      #{lunch == Money(1250)}")

# Compound assignment lowers to the same method: total = total.add(lunch)
var total = Money(0)
total += lunch
total += coffee
print("total      #{total.to_string()}")

# Strings order without any trait at all — that one is built in.
print()
print("apple before banana? #{"apple" < "banana"}")

# A type that says nothing about equality is still comparable with ==. It just means
# "the same object", which is the honest answer when nothing better has been defined.
class Tag {
    var name: String
    constructor(name: String) { self.name = name }
}

print("two identical tags equal? #{Tag("red") == Tag("red")}")
