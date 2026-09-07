## Int and Float are one number line for ==, and a Float field can be holding either --
## Whole(1) stores an Int where Whole(1.0) stores a Float, and == calls the two structs
## equal. Both hash through one form so that two keys == calls equal cannot land in
## different buckets, which is the difference between finding a key again and losing it.
struct Whole {
    var size: Float
    constructor(size: Float) { self.size = size }
}

print(Whole(1) == Whole(1.0))

var counts: Dictionary<Whole, String> = [:]
counts.set(Whole(1), "from an Int")
counts.set(Whole(1.0), "from a Float")

print(counts.count())
print(counts[Whole(1)])
