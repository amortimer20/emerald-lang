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

# Terminal styling is written in Emerald so it keeps normal named/defaulted
# arguments and composes through ordinary String interpolation.
class Console {
    enum Color {
        black, red, green, yellow, blue, magenta, cyan, white
        bright_black, bright_red, bright_green, bright_yellow
        bright_blue, bright_magenta, bright_cyan, bright_white
    }

    # Native: whether this execution emits ANSI SGR styling.
    func Console._color(): Bool { return false }

    # Native: removes complete ANSI SGR sequences, leaving other control text alone.
    func Console.plain(text: String): String { return text }

    func Console._layer(text: String, open: Int, close: Int): String {
        const opened = "\u{1B}[#{open}m"
        const closed = "\u{1B}[#{close}m"
        const reset = "\u{1B}[0m"
        return opened + text.replace(closed, closed + opened).replace(reset, reset + opened) + closed
    }

    func Console._code(color: Emerald.Console.Color): Int {
        return case color {
            when Emerald.Console.Color.black then 30
            when Emerald.Console.Color.red then 31
            when Emerald.Console.Color.green then 32
            when Emerald.Console.Color.yellow then 33
            when Emerald.Console.Color.blue then 34
            when Emerald.Console.Color.magenta then 35
            when Emerald.Console.Color.cyan then 36
            when Emerald.Console.Color.white then 37
            when Emerald.Console.Color.bright_black then 90
            when Emerald.Console.Color.bright_red then 91
            when Emerald.Console.Color.bright_green then 92
            when Emerald.Console.Color.bright_yellow then 93
            when Emerald.Console.Color.bright_blue then 94
            when Emerald.Console.Color.bright_magenta then 95
            when Emerald.Console.Color.bright_cyan then 96
            when Emerald.Console.Color.bright_white then 97
        }
    }

    func Console.style(text: String, foreground: Emerald.Console.Color? = nothing, background: Emerald.Console.Color? = nothing, bold: Bool = false, dim: Bool = false, italic: Bool = false, underline: Bool = false): String {
        if not Emerald.Console._color() {
            return text
        }
        var result = text
        if foreground != nothing {
            result = Emerald.Console._layer(result, Emerald.Console._code(foreground), 39)
        }
        if background != nothing {
            result = Emerald.Console._layer(result, Emerald.Console._code(background) + 10, 49)
        }
        if bold {
            result = Emerald.Console._layer(result, 1, 22)
        }
        if dim {
            result = Emerald.Console._layer(result, 2, 22)
        }
        if italic {
            result = Emerald.Console._layer(result, 3, 23)
        }
        if underline {
            result = Emerald.Console._layer(result, 4, 24)
        }
        return result
    }

    func Console.black(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.black) }
    func Console.red(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.red) }
    func Console.green(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.green) }
    func Console.yellow(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.yellow) }
    func Console.blue(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.blue) }
    func Console.magenta(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.magenta) }
    func Console.cyan(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.cyan) }
    func Console.white(text: String): String { return Emerald.Console.style(text, foreground: Emerald.Console.Color.white) }

    func Console.bold(text: String): String { return Emerald.Console.style(text, bold: true) }
    func Console.dim(text: String): String { return Emerald.Console.style(text, dim: true) }
    func Console.italic(text: String): String { return Emerald.Console.style(text, italic: true) }
    func Console.underline(text: String): String { return Emerald.Console.style(text, underline: true) }
}

# Section 9.3's repeatable randomness source. Its state is private and the
# interpreter supplies the generic collection operations.
class Random {
    var _state: Int

    constructor(seed: Int) {
        self._state = seed
    }
}

# Section 11.5's remaining comparison contract: arithmetic is registered by
# `@operator` on the concrete method that owns it.
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
