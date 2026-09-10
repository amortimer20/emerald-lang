## Naming Filtered is the other half of the row next door: it makes narrowing usable
## through a trait reference, and it narrows what fits to exactly the types that answer it
## the same way. A Set narrows to a Set, so a Set is correctly not one of them.
##
## Deck never wrote Filtered. It gets List<Int> from the trait's own default — declared
## once as `type Filtered = List<Item>` and resolved through whatever Item turned out to
## be — which is why an implementer with nothing different to say writes nothing at all.

class Deck with Iterable {
    type Item = Int

    var values: List<Int>

    constructor(values: List<Int>) {
        self.values = values
    }

    func each(step: func(Int)) {
        for value in self.values {
            step(value)
        }
    }
}

func big(items: Iterable<Item=Int, Filtered=List<Int>>): List<Int> {
    return items.filter { n => n > 2 }
}

print(big([1, 2, 3, 4]).join(", "))
print(big(Deck([1, 5, 9])).join(", "))
print(big([1, 2, 3, 4]).type_name())
