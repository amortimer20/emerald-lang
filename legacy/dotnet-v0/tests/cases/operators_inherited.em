## A subclass gets its base's operator.
class Weight with Addable {
    var grams: Int
    constructor(grams: Int) { self.grams = grams }
    func add(other: Weight): Weight { return Weight(self.grams + other.grams) }
    func to_string(): String { return "#{self.grams}g" }
}

class Parcel extends Weight {
}

print((Parcel(100) + Parcel(50)).to_string())
