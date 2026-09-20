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

# Section 15.3's filesystem failures. Native whole-file functions below build
# this ordinary Error value, so callers can catch filesystem failures without
# catching unrelated RuntimeErrors.
class FileError extends RuntimeError {
    constructor(message: String) {
        super(message)
    }
}

# Whole-file filesystem namespaces. Their bodies establish the ordinary
# type-level signatures; the interpreter supplies the native operation.
class File {
    func File.read(path: String): String { return "" }
    func File.write(path: String, contents: String) {}
    func File.append(path: String, contents: String) {}
    func File.read_lines(path: String): List[String] { return [] }
    func File.write_lines(path: String, lines: List[String]) {}
    func File.exists?(path: String): Bool { return false }
    func File.copy(source: String, destination: String) {}
    func File.move(source: String, destination: String) {}
    func File.delete(path: String) {}
}

class Directory {
    func Directory.exists?(path: String): Bool { return false }
    func Directory.create(path: String) {}
    func Directory.delete(path: String) {}
    func Directory.list(path: String): List[String] { return [] }
}

class Path {
    func Path.join(parts: List[String]): String { return "" }
    func Path.name(path: String): String { return "" }
    func Path.stem(path: String): String { return "" }
    func Path.extension(path: String): String { return "" }
    func Path.parent(path: String): String { return "" }
    func Path.absolute?(path: String): Bool { return false }
    func Path.absolute(path: String): String { return "" }
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
