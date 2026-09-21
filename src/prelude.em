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
    func File.open(path: String): FileHandle { return FileHandle() }
    func File.with_open(path: String, block: func(FileHandle)) {}
    func File.create(path: String): FileWriter { return FileWriter() }
    func File.with_writer(path: String, block: func(FileWriter)) {}
    func File.read(path: String): String { return "" }
    func File.read_binary(path: String): Bytes { return Bytes.from_list([]) }
    func File.write(path: String, contents: String) {}
    func File.write_binary(path: String, bytes: Bytes) {}
    func File.append(path: String, contents: String) {}
    func File.read_lines(path: String): List[String] { return [] }
    func File.write_lines(path: String, lines: List[String]) {}
    func File.exists?(path: String): Bool { return false }
    func File.copy(source: String, destination: String) {}
    func File.move(source: String, destination: String) {}
    func File.delete(path: String) {}
}

# A live, read-only text stream. `_id` is interpreter-managed state: programs
# obtain usable handles from `File.open`, then read or close them.
class FileHandle {
    var _id: Int = Program.arguments.count

    func read(): String { return "" }
    func read_line(): String? { return nothing }
    func read_bytes(count: Int): Bytes? { return nothing }
    func read_all_bytes(): Bytes { return Bytes.from_list([]) }
    func close() {}
}

# A live, write-only text stream. As with FileHandle, `_id` is private
# interpreter-managed state and `close` is safe to call more than once.
class FileWriter {
    var _id: Int = Program.arguments.count

    func write(text: String) {}
    func write_bytes(bytes: Bytes) {}
    func close() {}
}

# Raw immutable octets. The native runtime supplies construction and instance
# methods; this class only gives its type-level constructor a resolver key.
class Bytes {
    func Bytes.from_list(numbers: List[Int]): Bytes { return Bytes.from_list([]) }
}

class Directory {
    func Directory.exists?(path: String): Bool { return false }
    func Directory.create(path: String) {}
    func Directory.delete(path: String) {}
    func Directory.delete_recursive(path: String) {}
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

# Section 8.4's custom equality: `a == b` runs `a.equals(b)` on a type that
# adopts `Equatable`, in place of the default (structural for a struct or
# tuple, identity for a class); `!=` is always `not equals(other)`, never
# separately overridable. `Hashable` builds on it (11.2's `with Equatable`
# trait composition) because a hash must agree with equality (8.4): a type
# whose `equals` this replaces cannot safely keep the default structural
# hash, so adopting `Equatable` alone does not make a type a dictionary or
# set key again — `Hashable`'s own `hash()` is what does.
trait Equatable {
    func equals(other: Self): Bool
}

trait Hashable with Equatable {
    func hash(): Int
}

# Section 15.1's display contract. A type that adopts it renders through its
# own `to_string()` in `print`, `write`, and interpolation, wherever the value
# appears; one that does not keeps the field-based debug form. Adoption is
# explicit, as for every other trait: a method named `to_string` alone changes
# nothing about how a value displays.
trait Textual {
    func to_string(): String
}
