# Operators

## A type gives `+` a meaning by registering its `add` method. `Self` stands
## for the type itself, so both sides are the same type.
struct Money with Ordered {
    const cents: Int

    @operator("+")
    func add(other: Self): Self {
        return Money(self.cents + other.cents)
    }

    ## `Ordered` gives `<`, `<=`, `>`, and `>=` through one method: a negative
    ## result means `self` comes first. Comparing with `if` rather than
    ## subtracting avoids overflowing `Int` at its extremes.
    @override
    func compare(other: Self): Int {
        if self.cents < other.cents {
            return -1
        }
        if self.cents > other.cents {
            return 1
        }
        return 0
    }

    const text: String {
        return "#{self.cents} cents"
    }
}

const prices = [Money(1250), Money(399), Money(2075)]
var total = Money(0)
var dearest = prices[0]
for price in prices {
    total += price
    if price > dearest {
        dearest = price
    }
}
print("Total: #{total.text}")
print("Dearest: #{dearest.text}")

## A trait can still express its own ordinary requirement using `Self`.
trait Doubling {
    func doubled(): Self
}

struct Minutes with Doubling {
    const count: Int

    @override
    func doubled(): Self {
        return Minutes(self.count * 2)
    }
}

print(Minutes(45).doubled())
