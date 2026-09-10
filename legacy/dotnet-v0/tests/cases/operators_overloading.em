## Every overloadable operator, on one type.
struct Money with Addable, Subtractable, Multipliable, Equatable, Ordered {
    var cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }

    func add(other: Money): Money { return Money(self.cents + other.cents) }
    func subtract(other: Money): Money { return Money(self.cents - other.cents) }
    func multiply(factor: Int): Money { return Money(self.cents * factor) }
    func equals?(other: Money): Bool { return self.cents == other.cents }
    func compare(other: Money): Int { return self.cents - other.cents }

    func to_string(): String { return "#{self.cents}c" }
}

var lunch = Money(1250)
var coffee = Money(450)

print((lunch + coffee).to_string())
print((lunch - coffee).to_string())
print((coffee * 3).to_string())
print(lunch == Money(1250))
print(lunch != coffee)
print(lunch > coffee)
print(coffee <= Money(450))

## += lowers to the same method.
var total = Money(0)
total += lunch
total += coffee
print(total.to_string())
