# Section 11.5: an operator on a user type needs the prelude trait for it,
# the same type on both sides, and a method that leaves its operands alone.

struct Point {
    const x: Int
}

struct Vector with Addable {
    const x: Float

    @override
    func add(other: Self): Self {
        return Vector(self.x + other.x)
    }
}

struct Tally with Addable {
    var n: Int

    @override
    func add(other: Self): Self {
        self.n += other.n
        return self
    }
}

trait Doubling {
    func doubled(): Self {
        return self + self
    }
}

func combine(a: Addable, b: Addable) {
    print(a + b)
}

print(Point(1) + Point(2))
print(Point(1) < Point(2))
print(Vector(1) + 2.0)
print(2 * Vector(1))
print(Vector(1) % Vector(2))
print(Tally(1) + Tally(2))

var total = Vector(0)
total += 1

# While an object is built, an operator on `self` is a call through `self`
# (10.2): it waits for every field, and a class's method could be overridden.
struct Pair with Ordered {
    const low: Int
    const high: Int

    constructor(low: Int, high: Int) {
        self.low = low
        print(self < Pair(0, 0))
        self.high = high
    }

    @override
    func compare(other: Self): Int {
        return self.low - other.low
    }
}

class Level with Ordered {
    const rank: Int

    constructor(rank: Int) {
        self.rank = rank
        print(self > Level(0))
    }

    @override
    func compare(other: Level): Int {
        return self.rank - other.rank
    }
}
