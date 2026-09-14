# Section 13's common root for every value that may be raised.
class Error {
    const message: String
}

class RuntimeError extends Error {
    constructor(message: String) {
        super(message)
    }
}

class AssertionError extends Error {
    constructor(message: String) {
        super(message)
    }
}

# Section 11.5's operator contracts. Every program sees these names, and a
# program's own declaration of the same name takes its place.
#
# `a + b` runs `a.add(b)` on a type that adopts `Addable`, and `a < b` runs
# `a.compare(b) < 0` on one that adopts `Ordered`.

trait Addable {
    func add(other: Self): Self
}

trait Subtractable {
    func subtract(other: Self): Self
}

trait Multipliable {
    func multiply(other: Self): Self
}

trait Divisible {
    func divide(other: Self): Self
}

trait Ordered {
    func compare(other: Self): Int
}
