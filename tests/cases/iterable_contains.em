## contains? is written once against find, which is written once against each -- and it
## uses == underneath, so it needs nothing from Item beyond what every type already has.
class Bag with Iterable {
    type Item = Int
    var values: List<Int>
    constructor(values: List<Int>) { self.values = values }
    func each(step: func(Int)) {
        for v in self.values { step(v) }
    }
}

var bag = Bag([3, 1, 4, 1, 5])
print(bag.contains?(4))
print(bag.contains?(9))
