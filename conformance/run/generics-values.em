# Section 11.3: a generic struct with two types, its value semantics through a
# type parameter, keys, captured methods, optional chaining, and `Self`.
struct Pair[First, Second] {
    var first: First
    var second: Second

    func swapped(): Pair[Second, First] {
        return Pair(self.second, self.first)
    }

    func with_first(first: First): Self {
        return Pair(first, self.second)
    }

    func set_second(second: Second) {
        self.second = second
    }
}

const ava = Pair("Ava", 12)
print(ava, ava.first, ava.second + 1)
print(ava.swapped(), ava.swapped().first * 2)
print(ava.with_first("Noah"))

# A struct holds its own copy of what it is given; a class value is shared.
struct Point {
    var x: Int
}

class Counter {
    var count: Int = 0
}

var original = Pair(Point(1), Counter())
var copy = original
copy.first.x = 5
copy.second.count = 9
print(original.first.x, copy.first.x, original.second.count)

# A changing method of a generic struct changes the binding it is called on.
var mutable = Pair("score", 1)
mutable.set_second(2)
print(mutable.second)

# A struct of keys is a key, whatever its types.
const ages: Dict[Pair[String, Int], String] = [ava: "first"]
print(ages[Pair("Ava", 12)].or("missing"))
const seen: Set[Pair[Int, Int]] = [Pair(1, 2), Pair(1, 2), Pair(2, 1)]
print(seen.count)

# A captured method keeps its types.
const swap = ava.swapped
print(swap().second)

# Optional chaining reads a field of the type it was given.
const maybe: Pair[String, Float]? = Pair("pi", 3)
print(maybe?.second)

# Types written in collections and functions.
const pairs: List[Pair[String, Int]] = [Pair("a", 1), Pair("b", 2)]
print(pairs.map { pair => pair.second }.sum())
const make: func(Int): Pair[Int, Int] = { n => Pair(n, n * n) }
print(make(4))
