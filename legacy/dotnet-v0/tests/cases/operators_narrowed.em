## Narrowing has to keep the type, not just prove it is not nothing — an operator
## needs to find the method on it.
class Weight with Addable {
    var grams: Int
    constructor(grams: Int) { self.grams = grams }
    func add(other: Weight): Weight { return Weight(self.grams + other.grams) }
    func to_string(): String { return "#{self.grams}g" }
}

var maybe: Weight? = Weight(5)
if maybe != nothing {
    print((maybe + Weight(5)).to_string())
}
