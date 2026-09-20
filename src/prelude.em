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

class FileError extends RuntimeError {
    constructor(message: String) {
        super(message)
    }
}

# Section 15.3's lexical path namespace. `absolute` joins the whole-file
# filesystem slice because resolving a path consults the host filesystem.
class Path {
    func Path.join(parts: List[String]): String { return "" }
    func Path.name(path: String): String { return "" }
    func Path.stem(path: String): String { return "" }
    func Path.extension(path: String): String { return "" }
    func Path.parent(path: String): String { return "" }
    func Path.absolute?(path: String): Bool { return false }
}

# Section 9.3's repeatable randomness source. Its state is private and the
# interpreter supplies the generic collection operations.
class Random {
    var _state: Int

    constructor(seed: Int) {
        self._state = seed
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
