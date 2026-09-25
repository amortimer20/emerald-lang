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

# Dates and times (15.8). Everything below is ordinary Emerald: the calendar
# arithmetic, validation, parsing, and display, so any backend inherits them
# unchanged. Bodies write `Emerald.` in front of every built-in they name, so a
# program declaring its own `Date` or `Duration` cannot capture them.

# Invalid dates, times, and text: a message naming the part that is wrong and
# the range it must be in.
class DateTimeError extends RuntimeError {
    constructor(message: String) {
        super(message)
    }
}

# The days of the week, Monday first as in ISO 8601. Declaration order is not
# an ordering (12): a week is a cycle, and where it starts depends on culture.
enum Weekday with Textual {
    monday, tuesday, wednesday, thursday, friday, saturday, sunday

    @override
    func to_string(): String {
        return case self {
            when Emerald.Weekday.monday then "Monday"
            when Emerald.Weekday.tuesday then "Tuesday"
            when Emerald.Weekday.wednesday then "Wednesday"
            when Emerald.Weekday.thursday then "Thursday"
            when Emerald.Weekday.friday then "Friday"
            when Emerald.Weekday.saturday then "Saturday"
            when Emerald.Weekday.sunday then "Sunday"
        }
    }
}

# An exact length of time, to the nanosecond, which may be negative. A day
# here is exactly 24 hours, unlike a calendar day in `Date.add(days:)`. It is
# stored as whole seconds plus a nanosecond part from 0 through 999999999, so
# two equal lengths always have equal fields.
struct Duration with Ordered, Textual {
    const _seconds: Int
    const _nanoseconds: Int

    constructor(days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0) {
        const parts = (milliseconds % 1000) * 1000000 + (microseconds % 1000000) * 1000 + nanoseconds % 1000000000
        self._seconds = days * 86400 + hours * 3600 + minutes * 60 + seconds + milliseconds // 1000 + microseconds // 1000000 + nanoseconds // 1000000000 + parts // 1000000000
        self._nanoseconds = parts % 1000000000
    }

    const total_days: Float {
        return self._total_seconds() / 86400
    }

    const total_hours: Float {
        return self._total_seconds() / 3600
    }

    const total_minutes: Float {
        return self._total_seconds() / 60
    }

    const total_seconds: Float {
        return self._total_seconds()
    }

    const total_milliseconds: Float {
        return self._seconds * 1000.0 + self._nanoseconds / 1000000
    }

    func _total_seconds(): Float {
        return self._seconds + self._nanoseconds / 1000000000
    }

    func zero?(): Bool {
        return self._seconds == 0 and self._nanoseconds == 0
    }

    func negative?(): Bool {
        return self._seconds < 0
    }

    func abs(): Self {
        return if self.negative?() then self._negated() else self
    }

    func _negated(): Self {
        if self._nanoseconds == 0 {
            return Emerald.Duration(seconds: -self._seconds)
        }
        return Emerald.Duration(seconds: -self._seconds - 1, nanoseconds: 1000000000 - self._nanoseconds)
    }

    @operator("+")
    func add(other: Self): Self {
        return Emerald.Duration(seconds: self._seconds + other._seconds, nanoseconds: self._nanoseconds + other._nanoseconds)
    }

    @operator("-")
    func subtract(other: Self): Self {
        return Emerald.Duration(seconds: self._seconds - other._seconds, nanoseconds: self._nanoseconds - other._nanoseconds)
    }

    @operator("*")
    func times(factor: Int): Emerald.Duration {
        # Splitting the factor keeps the nanosecond product inside `Int`.
        const high = factor // 1000000000
        const low = factor % 1000000000
        return Emerald.Duration(seconds: self._seconds * factor + self._nanoseconds * high, nanoseconds: self._nanoseconds * low)
    }

    # Rounds toward zero, to the nearest nanosecond.
    @operator("/")
    func divided_by(divisor: Int): Emerald.Duration {
        if divisor == 0 {
            raise Emerald.DateTimeError("a Duration cannot be divided by zero")
        }
        const magnitude = self.abs()
        const whole = divisor.abs()
        const part = Emerald.Duration._scaled_quotient(magnitude._seconds % whole, magnitude._nanoseconds, whole)
        const result = Emerald.Duration(seconds: magnitude._seconds // whole, nanoseconds: part)
        return if self.negative?() != (divisor < 0) then result._negated() else result
    }

    # How many times `other` fits into this one.
    @operator("/")
    func ratio_to(other: Emerald.Duration): Float {
        if other.zero?() {
            raise Emerald.DateTimeError("a Duration cannot be divided by a zero Duration")
        }
        return self._total_seconds() / other._total_seconds()
    }

    # (remainder * 1000000000 + nanoseconds) // divisor, where remainder is
    # below divisor and nanoseconds is below 1000000000, without leaving `Int`.
    func Duration._scaled_quotient(remainder: Int, nanoseconds: Int, divisor: Int): Int {
        if divisor <= 9000000000 {
            return (remainder * 1000000000 + nanoseconds) // divisor
        }
        # Binary long division: `left` stays below `divisor`, so no step
        # doubles or adds past it before subtracting.
        var quotient = 0
        var left = 0
        for bit in 29.down_to(0) {
            quotient = quotient * 2
            if left >= divisor - left {
                left = left - (divisor - left)
                quotient += 1
            }
            else {
                left = left * 2
            }
            if (1000000000 // 2 ** bit) % 2 == 1 {
                if left >= divisor - remainder {
                    left = left - (divisor - remainder)
                    quotient += 1
                }
                else {
                    left = left + remainder
                }
            }
        }
        if left >= divisor - nanoseconds {
            quotient += 1
        }
        return quotient
    }

    @override
    func compare(other: Self): Int {
        if self._seconds != other._seconds {
            return if self._seconds < other._seconds then -1 else 1
        }
        if self._nanoseconds != other._nanoseconds {
            return if self._nanoseconds < other._nanoseconds then -1 else 1
        }
        return 0
    }

    # `2d 3h`, `1h 30m`, `1.25s`, `0s`, `-5m`: the nonzero units, largest first.
    @override
    func to_string(): String {
        if self.zero?() {
            return "0s"
        }
        if self.negative?() {
            return "-" + self._negated().to_string()
        }
        var text = ""
        const days = self._seconds // 86400
        const hours = self._seconds % 86400 // 3600
        const minutes = self._seconds % 3600 // 60
        const seconds = self._seconds % 60
        if days > 0 {
            text += " #{days}d"
        }
        if hours > 0 {
            text += " #{hours}h"
        }
        if minutes > 0 {
            text += " #{minutes}m"
        }
        if self._nanoseconds > 0 {
            text += " #{seconds}.#{Emerald.Duration._fraction(self._nanoseconds)}s"
        }
        else if seconds > 0 {
            text += " #{seconds}s"
        }
        return text.remove_prefix(" ")
    }

    # The digits after a decimal point for a nanosecond count, without
    # trailing zeros: 250000000 is "25".
    func Duration._fraction(nanoseconds: Int): String {
        var digits = nanoseconds.to_string().pad_start(9, "0")
        while digits.ends_with?("0") {
            digits = digits.remove_suffix("0")
        }
        return digits
    }
}

# A calendar date with no time of day or time zone, in the proleptic Gregorian
# calendar from year 1 through 9999.
struct Date with Ordered, Textual {
    const year: Int
    const month: Int
    const day: Int

    const Date._month_names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    const Date._weekdays = [Emerald.Weekday.monday, Emerald.Weekday.tuesday, Emerald.Weekday.wednesday, Emerald.Weekday.thursday, Emerald.Weekday.friday, Emerald.Weekday.saturday, Emerald.Weekday.sunday]

    constructor(year: Int, month: Int, day: Int) {
        const problem = Emerald.Date._problem(year, month, day)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        self.year = year
        self.month = month
        self.day = day
    }

    func Date.parse(text: String): Emerald.Date {
        const problem = Emerald.Date._text_problem(text)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        return Emerald.Date._from_text(text)
    }

    func Date.parse_maybe(text: String): Emerald.Date? {
        if Emerald.Date._text_problem(text) != nothing {
            return nothing
        }
        return Emerald.Date._from_text(text)
    }

    const weekday: Emerald.Weekday {
        return Emerald.Date._weekdays[(self._days() + 3) % 7]
    }

    const month_name: String {
        return Emerald.Date._month_names[self.month - 1]
    }

    const day_of_year: Int {
        return self._days() - Emerald.Date._days_from_civil(self.year, 1, 1) + 1
    }

    const days_in_month: Int {
        return Emerald.Date._month_length(self.year, self.month)
    }

    func leap_year?(): Bool {
        return Emerald.Date._leap?(self.year)
    }

    # Years and months first, keeping the day when that month has it and
    # otherwise using its last day; then weeks and days.
    func add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0): Self {
        const index = self.year * 12 + self.month - 1 + years * 12 + months
        const year = index // 12
        const month = index % 12 + 1
        const year_problem = Emerald.Date._year_problem(year)
        if year_problem != nothing {
            raise Emerald.DateTimeError(year_problem)
        }
        const moved = Emerald.Date(year, month, self.day.clamp(1, Emerald.Date._month_length(year, month)))
        if weeks == 0 and days == 0 {
            return moved
        }
        return Emerald.Date._from_days(moved._days() + weeks * 7 + days)
    }

    func subtract(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0): Self {
        return self.add(years: -years, months: -months, weeks: -weeks, days: -days)
    }

    func days_until(other: Self): Int {
        return other._days() - self._days()
    }

    # Whole months: the most that `add(months:)` can move this date without
    # passing `other`.
    func months_until(other: Self): Int {
        var months = other.year * 12 + other.month - (self.year * 12 + self.month)
        if months > 0 and self.add(months: months) > other {
            months -= 1
        }
        else if months < 0 and self.add(months: months) < other {
            months += 1
        }
        return months
    }

    # Whole years, so a birth date's `years_until(today)` is an age.
    func years_until(other: Self): Int {
        const months = self.months_until(other)
        return if months >= 0 then months // 12 else -((-months) // 12)
    }

    @override
    func compare(other: Self): Int {
        return self._days() - other._days()
    }

    @override
    func to_string(): String {
        return "#{self.year.to_string().pad_start(4, "0")}-#{self.month.to_string().pad_start(2, "0")}-#{self.day.to_string().pad_start(2, "0")}"
    }

    # Days since 1970-01-01, which is day 0.
    func _days(): Int {
        return Emerald.Date._days_from_civil(self.year, self.month, self.day)
    }

    func Date._leap?(year: Int): Bool {
        return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    }

    func Date._month_length(year: Int, month: Int): Int {
        if month == 2 {
            return if Emerald.Date._leap?(year) then 29 else 28
        }
        return if month == 4 or month == 6 or month == 9 or month == 11 then 30 else 31
    }

    func Date._year_problem(year: Int): String? {
        if year < 1 or year > 9999 {
            return "year #{year} is not between 1 and 9999"
        }
        return nothing
    }

    func Date._problem(year: Int, month: Int, day: Int): String? {
        const year_problem = Emerald.Date._year_problem(year)
        if year_problem != nothing {
            return year_problem
        }
        if month < 1 or month > 12 {
            return "month #{month} is not between 1 and 12"
        }
        const length = Emerald.Date._month_length(year, month)
        if day < 1 or day > length {
            return "day #{day} is not between 1 and #{length}: #{Emerald.Date._month_names[month - 1]} #{year} has #{length} days"
        }
        return nothing
    }

    # Howard Hinnant's days_from_civil, in floor arithmetic.
    func Date._days_from_civil(year: Int, month: Int, day: Int): Int {
        const shifted = if month <= 2 then year - 1 else year
        const era = shifted // 400
        const year_of_era = shifted - era * 400
        const day_of_year = (153 * ((month + 9) % 12) + 2) // 5 + day - 1
        const day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
        return era * 146097 + day_of_era - 719468
    }

    # The inverse, Hinnant's civil_from_days.
    func Date._from_days(days: Int): Emerald.Date {
        const shifted = days + 719468
        const era = shifted // 146097
        const day_of_era = shifted - era * 146097
        const year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
        const day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
        const month_index = (5 * day_of_year + 2) // 153
        const day = day_of_year - (153 * month_index + 2) // 5 + 1
        const month = if month_index < 10 then month_index + 3 else month_index - 9
        const year = year_of_era + era * 400 + (if month <= 2 then 1 else 0)
        return Emerald.Date(year, month, day)
    }

    # The number written in `count` ASCII digits starting at `start`, or
    # nothing when any of them is not a digit.
    func Date._digits(points: List[Int], start: Int, count: Int): Int? {
        var value = 0
        for index in start..<start + count {
            const point = points[index]
            if point < 48 or point > 57 {
                return nothing
            }
            value = value * 10 + point - 48
        }
        return value
    }

    func Date._text_problem(text: String): String? {
        const points = text.trim().code_points()
        const shape = "\"#{text}\" is not a date written as YYYY-MM-DD, such as 2026-09-25"
        if points.count != 10 or points[4] != 45 or points[7] != 45 {
            return shape
        }
        const year = Emerald.Date._digits(points, 0, 4)
        const month = Emerald.Date._digits(points, 5, 2)
        const day = Emerald.Date._digits(points, 8, 2)
        if year == nothing or month == nothing or day == nothing {
            return shape
        }
        const problem = Emerald.Date._problem(year, month, day)
        if problem != nothing {
            return "\"#{text}\" is not a valid date: #{problem}"
        }
        return nothing
    }

    # Only after `_text_problem` has accepted the text.
    func Date._from_text(text: String): Emerald.Date {
        const points = text.trim().code_points()
        return Emerald.Date(Emerald.Date._digits(points, 0, 4).or(0), Emerald.Date._digits(points, 5, 2).or(0), Emerald.Date._digits(points, 8, 2).or(0))
    }
}
