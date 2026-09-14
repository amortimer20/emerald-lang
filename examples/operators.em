# Operators

## A type gives `+` a meaning by adopting the prelude's `Addable` and supplying
## `add`. `Self` stands for the type itself, so both sides are the same type.
struct Money with Addable, Ordered {
    const cents: Int

    @override
    func add(other: Self): Self {
        return Money(self.cents + other.cents)
    }

    ## `Ordered` gives `<`, `<=`, `>`, and `>=` through one method: a negative
    ## result means `self` comes first.
    @override
    func compare(other: Self): Int {
        return self.cents - other.cents
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

## Inside a trait, `Self` is whichever type adopts it, so a default can combine
## values of that type without knowing what it is.
trait Doubling with Addable {
    func doubled(): Self {
        return self + self
    }
}

struct Minutes with Doubling {
    const count: Int

    @override
    func add(other: Self): Self {
        return Minutes(self.count + other.count)
    }
}

print(Minutes(45).doubled())
