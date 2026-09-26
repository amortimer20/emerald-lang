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

    # Whole units, rounded toward zero: `Duration(minutes: 90).whole_hours` is 1.
    const whole_days: Int {
        return self._whole(1, 86400)
    }

    const whole_hours: Int {
        return self._whole(1, 3600)
    }

    const whole_minutes: Int {
        return self._whole(1, 60)
    }

    const whole_seconds: Int {
        return self._whole(1, 1)
    }

    const whole_milliseconds: Int {
        return self._whole(1000, 1)
    }

    const whole_microseconds: Int {
        return self._whole(1000000, 1)
    }

    const whole_nanoseconds: Int {
        return self._whole(1000000000, 1)
    }

    # How many `per_unit`s of a unit there are `per_second` of in a second,
    # counted on the magnitude so the result rounds toward zero.
    func _whole(per_second: Int, per_unit: Int): Int {
        const magnitude = self.abs()
        const value = (magnitude._seconds * per_second + magnitude._nanoseconds // (1000000000 // per_second)) // per_unit
        return if self.negative?() then -value else value
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

# Shared by the date and time types, and private to this file, so programs
# neither see nor capture them.

# A function rather than a module-level list: a module binding in the prelude
# would take part in every program's module-setup ordering (14.1).
func _month_name(month: Int): String {
    return ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][month - 1]
}

func _leap?(year: Int): Bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
}

func _month_length(year: Int, month: Int): Int {
    if month == 2 {
        return if _leap?(year) then 29 else 28
    }
    return if month == 4 or month == 6 or month == 9 or month == 11 then 30 else 31
}

func _year_problem(year: Int): String? {
    if year < 1 or year > 9999 {
        return "year #{year} is not between 1 and 9999"
    }
    return nothing
}

func _date_problem(year: Int, month: Int, day: Int): String? {
    const year_problem = _year_problem(year)
    if year_problem != nothing {
        return year_problem
    }
    if month < 1 or month > 12 {
        return "month #{month} is not between 1 and 12"
    }
    const length = _month_length(year, month)
    if day < 1 or day > length {
        return "day #{day} is not between 1 and #{length}: #{_month_name(month)} #{year} has #{length} days"
    }
    return nothing
}

func _time_problem(hour: Int, minute: Int, second: Int, nanosecond: Int): String? {
    if hour < 0 or hour > 23 {
        return "hour #{hour} is not between 0 and 23"
    }
    if minute < 0 or minute > 59 {
        return "minute #{minute} is not between 0 and 59"
    }
    if second < 0 or second > 59 {
        return "second #{second} is not between 0 and 59"
    }
    if nanosecond < 0 or nanosecond > 999999999 {
        return "nanosecond #{nanosecond} is not between 0 and 999999999"
    }
    return nothing
}

# A time of day moved by an exact amount: the whole days it crossed, then the
# new second of the day and nanosecond. Each unit is split into whole seconds
# and a remainder, so no product leaves `Int` for any reasonable amount.
func _shifted(second_of_day: Int, nanosecond: Int, hours: Int, minutes: Int, seconds: Int, milliseconds: Int, microseconds: Int, nanoseconds: Int): (Int, Int, Int) {
    const parts = nanosecond + (milliseconds % 1000) * 1000000 + (microseconds % 1000000) * 1000 + nanoseconds % 1000000000
    const total = second_of_day + hours * 3600 + minutes * 60 + seconds + milliseconds // 1000 + microseconds // 1000000 + nanoseconds // 1000000000 + parts // 1000000000
    return (total // 86400, total % 86400, parts % 1000000000)
}

# The digits after a decimal point for a nanosecond count, in groups of
# three: 250000000 is ".250". Nothing at all for a whole second.
func _second_fraction(nanosecond: Int): String {
    if nanosecond == 0 {
        return ""
    }
    if nanosecond % 1000000 == 0 {
        return "." + (nanosecond // 1000000).to_string().pad_start(3, "0")
    }
    if nanosecond % 1000 == 0 {
        return "." + (nanosecond // 1000).to_string().pad_start(6, "0")
    }
    return "." + nanosecond.to_string().pad_start(9, "0")
}

func _two_digits(value: Int): String {
    return value.to_string().pad_start(2, "0")
}

# Howard Hinnant's days_from_civil, in floor arithmetic: days since
# 1970-01-01, which is day 0.
func _days_from_civil(year: Int, month: Int, day: Int): Int {
    const shifted = if month <= 2 then year - 1 else year
    const era = shifted // 400
    const year_of_era = shifted - era * 400
    const day_of_year = (153 * ((month + 9) % 12) + 2) // 5 + day - 1
    const day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    return era * 146097 + day_of_era - 719468
}

# The inverse, Hinnant's civil_from_days: the year, month, and day.
func _civil_from_days(days: Int): (Int, Int, Int) {
    const shifted = days + 719468
    const era = shifted // 146097
    const day_of_era = shifted - era * 146097
    const year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
    const month_index = (5 * day_of_year + 2) // 153
    const day = day_of_year - (153 * month_index + 2) // 5 + 1
    const month = if month_index < 10 then month_index + 3 else month_index - 9
    return (year_of_era + era * 400 + (if month <= 2 then 1 else 0), month, day)
}

# An offset from UTC written as +HH:MM or -HH:MM at `start`, in seconds, or
# nothing when it is not written that way or is past 18 hours.
func _offset_at(points: List[Int], start: Int): Int? {
    if points.count != start + 6 or (points[start] != 43 and points[start] != 45) or points[start + 3] != 58 {
        return nothing
    }
    const hours = _digits(points, start + 1, 2)
    const minutes = _digits(points, start + 4, 2)
    if hours == nothing or minutes == nothing or minutes > 59 or hours * 60 + minutes > 18 * 60 {
        return nothing
    }
    const seconds = hours * 3600 + minutes * 60
    return if points[start] == 45 then -seconds else seconds
}

# Text is read as code points, since every accepted form is ASCII.

# The number written in `count` ASCII digits starting at `start`, or nothing
# when any of them is not a digit.
func _digits(points: List[Int], start: Int, count: Int): Int? {
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

# Whether YYYY-MM-DD starts at `start`, ignoring what follows it.
func _date_shaped?(points: List[Int], start: Int): Bool {
    if points.count < start + 10 or points[start + 4] != 45 or points[start + 7] != 45 {
        return false
    }
    return _digits(points, start, 4) != nothing and _digits(points, start + 5, 2) != nothing and _digits(points, start + 8, 2) != nothing
}

func _date_at(points: List[Int], start: Int): (Int, Int, Int) {
    return (_digits(points, start, 4).or(0), _digits(points, start + 5, 2).or(0), _digits(points, start + 8, 2).or(0))
}

# Whether exactly HH:MM, HH:MM:SS, or HH:MM:SS.fraction runs from `start` to
# `end`, with one to nine fraction digits.
func _time_shaped?(points: List[Int], start: Int, end: Int): Bool {
    const length = end - start
    if not (length == 5 or length == 8 or (length >= 10 and length <= 18)) {
        return false
    }
    if points[start + 2] != 58 or _digits(points, start, 2) == nothing or _digits(points, start + 3, 2) == nothing {
        return false
    }
    if length >= 8 and (points[start + 5] != 58 or _digits(points, start + 6, 2) == nothing) {
        return false
    }
    return length < 10 or (points[start + 8] == 46 and _digits(points, start + 9, length - 9) != nothing)
}

func _time_at(points: List[Int], start: Int, end: Int): (Int, Int, Int, Int) {
    const length = end - start
    const second = if length >= 8 then _digits(points, start + 6, 2).or(0) else 0
    var nanosecond = 0
    if length >= 10 {
        nanosecond = _digits(points, start + 9, length - 9).or(0) * 10 ** (18 - length)
    }
    return (_digits(points, start, 2).or(0), _digits(points, start + 3, 2).or(0), second, nanosecond)
}

# A calendar date with no time of day or time zone, in the proleptic Gregorian
# calendar from year 1 through 9999.
struct Date with Ordered, Textual {
    const year: Int
    const month: Int
    const day: Int

    const Date._weekdays = [Emerald.Weekday.monday, Emerald.Weekday.tuesday, Emerald.Weekday.wednesday, Emerald.Weekday.thursday, Emerald.Weekday.friday, Emerald.Weekday.saturday, Emerald.Weekday.sunday]

    constructor(year: Int, month: Int, day: Int) {
        const problem = _date_problem(year, month, day)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        self.year = year
        self.month = month
        self.day = day
    }

    # Today's date in `zone`.
    func Date.today(zone: Emerald.TimeZone = Emerald.TimeZone.local): Emerald.Date {
        return Emerald.Instant.now().to_date_time(zone).date
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
        return _month_name(self.month)
    }

    const day_of_year: Int {
        return self._days() - _days_from_civil(self.year, 1, 1) + 1
    }

    const days_in_month: Int {
        return _month_length(self.year, self.month)
    }

    func leap_year?(): Bool {
        return _leap?(self.year)
    }

    # Years and months first, keeping the day when that month has it and
    # otherwise using its last day; then weeks and days.
    func add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0): Self {
        const index = self.year * 12 + self.month - 1 + years * 12 + months
        const year = index // 12
        const month = index % 12 + 1
        const year_problem = _year_problem(year)
        if year_problem != nothing {
            raise Emerald.DateTimeError(year_problem)
        }
        const moved = Emerald.Date(year, month, self.day.clamp(1, _month_length(year, month)))
        if weeks == 0 and days == 0 {
            return moved
        }
        const (year_moved, month_moved, day_moved) = _civil_from_days(moved._days() + weeks * 7 + days)
        return Emerald.Date(year_moved, month_moved, day_moved)
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

    # This date at a time of day.
    func at(time: Emerald.Time): Emerald.DateTime {
        return Emerald.DateTime(self.year, self.month, self.day, time.hour, time.minute, time.second, time.nanosecond)
    }

    @override
    func compare(other: Self): Int {
        return self._days() - other._days()
    }

    @override
    func to_string(): String {
        return "#{self.year.to_string().pad_start(4, "0")}-#{_two_digits(self.month)}-#{_two_digits(self.day)}"
    }

    # Days since 1970-01-01, which is day 0.
    func _days(): Int {
        return _days_from_civil(self.year, self.month, self.day)
    }

    func Date._text_problem(text: String): String? {
        const points = text.trim().code_points()
        if points.count != 10 or not _date_shaped?(points, 0) {
            return "\"#{text}\" is not a date written as YYYY-MM-DD, such as 2026-09-25"
        }
        const (year, month, day) = _date_at(points, 0)
        const problem = _date_problem(year, month, day)
        if problem != nothing {
            return "\"#{text}\" is not a valid date: #{problem}"
        }
        return nothing
    }

    # Only after `_text_problem` has accepted the text.
    func Date._from_text(text: String): Emerald.Date {
        const (year, month, day) = _date_at(text.trim().code_points(), 0)
        return Emerald.Date(year, month, day)
    }
}

# A time on the clock with no date or time zone, to the nanosecond. Moving it
# wraps around midnight.
struct Time with Ordered, Textual {
    const hour: Int
    const minute: Int
    const second: Int
    const nanosecond: Int

    constructor(hour: Int, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) {
        const problem = _time_problem(hour, minute, second, nanosecond)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    # The time on the clock in `zone` now.
    func Time.now(zone: Emerald.TimeZone = Emerald.TimeZone.local): Emerald.Time {
        return Emerald.Instant.now().to_date_time(zone).time
    }

    func Time.parse(text: String): Emerald.Time {
        const problem = Emerald.Time._text_problem(text)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        return Emerald.Time._from_text(text)
    }

    func Time.parse_maybe(text: String): Emerald.Time? {
        if Emerald.Time._text_problem(text) != nothing {
            return nothing
        }
        return Emerald.Time._from_text(text)
    }

    func add(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0): Self {
        const (_, second_of_day, nanosecond) = _shifted(self._second_of_day(), self.nanosecond, hours, minutes, seconds, milliseconds, microseconds, nanoseconds)
        return Emerald.Time(second_of_day // 3600, second_of_day % 3600 // 60, second_of_day % 60, nanosecond)
    }

    func subtract(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0): Self {
        return self.add(hours: -hours, minutes: -minutes, seconds: -seconds, milliseconds: -milliseconds, microseconds: -microseconds, nanoseconds: -nanoseconds)
    }

    @override
    func compare(other: Self): Int {
        return (self._second_of_day() - other._second_of_day()) * 1000000000 + self.nanosecond - other.nanosecond
    }

    # HH:MM:SS, with a fraction of a second only when there is one.
    @override
    func to_string(): String {
        return "#{_two_digits(self.hour)}:#{_two_digits(self.minute)}:#{_two_digits(self.second)}#{_second_fraction(self.nanosecond)}"
    }

    func _second_of_day(): Int {
        return self.hour * 3600 + self.minute * 60 + self.second
    }

    func Time._text_problem(text: String): String? {
        const points = text.trim().code_points()
        if not _time_shaped?(points, 0, points.count) {
            return "\"#{text}\" is not a time written as HH:MM or HH:MM:SS, such as 14:30"
        }
        const (hour, minute, second, nanosecond) = _time_at(points, 0, points.count)
        const problem = _time_problem(hour, minute, second, nanosecond)
        if problem != nothing {
            return "\"#{text}\" is not a valid time: #{problem}"
        }
        return nothing
    }

    # Only after `_text_problem` has accepted the text.
    func Time._from_text(text: String): Emerald.Time {
        const points = text.trim().code_points()
        const (hour, minute, second, nanosecond) = _time_at(points, 0, points.count)
        return Emerald.Time(hour, minute, second, nanosecond)
    }
}

# A date and a time of day with no time zone: what a calendar and a wall clock
# show together.
struct DateTime with Ordered, Textual {
    const date: Emerald.Date
    const time: Emerald.Time

    constructor(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) {
        self.date = Emerald.Date(year, month, day)
        self.time = Emerald.Time(hour, minute, second, nanosecond)
    }

    # What a calendar and clock in `zone` show now.
    func DateTime.now(zone: Emerald.TimeZone = Emerald.TimeZone.local): Emerald.DateTime {
        return Emerald.Instant.now().to_date_time(zone)
    }

    func DateTime.parse(text: String): Emerald.DateTime {
        const problem = Emerald.DateTime._text_problem(text)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        return Emerald.DateTime._from_text(text)
    }

    func DateTime.parse_maybe(text: String): Emerald.DateTime? {
        if Emerald.DateTime._text_problem(text) != nothing {
            return nothing
        }
        return Emerald.DateTime._from_text(text)
    }

    const year: Int {
        return self.date.year
    }

    const month: Int {
        return self.date.month
    }

    const day: Int {
        return self.date.day
    }

    const hour: Int {
        return self.time.hour
    }

    const minute: Int {
        return self.time.minute
    }

    const second: Int {
        return self.time.second
    }

    const nanosecond: Int {
        return self.time.nanosecond
    }

    const weekday: Emerald.Weekday {
        return self.date.weekday
    }

    # Years and months first, as `Date.add` moves them; then weeks and days,
    # together with any whole days the time units carry past midnight.
    func add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0): Self {
        const time = self.time
        const (carried, second_of_day, nanosecond) = _shifted(time.hour * 3600 + time.minute * 60 + time.second, time.nanosecond, hours, minutes, seconds, milliseconds, microseconds, nanoseconds)
        const date = self.date.add(years: years, months: months, weeks: weeks, days: days + carried)
        return Emerald.DateTime(date.year, date.month, date.day, second_of_day // 3600, second_of_day % 3600 // 60, second_of_day % 60, nanosecond)
    }

    func subtract(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0): Self {
        return self.add(years: -years, months: -months, weeks: -weeks, days: -days, hours: -hours, minutes: -minutes, seconds: -seconds, milliseconds: -milliseconds, microseconds: -microseconds, nanoseconds: -nanoseconds)
    }

    # The moment this date and time is in `zone`. When clocks go back, a time
    # happens twice and this is the earlier; when they go forward, a time is
    # skipped and this moves it forward by the gap, as Temporal does.
    func to_instant(zone: Emerald.TimeZone = Emerald.TimeZone.local): Emerald.Instant {
        const seconds = _days_from_civil(self.year, self.month, self.day) * 86400 + self.hour * 3600 + self.minute * 60 + self.second
        const naive = Emerald.Instant.from_unix_seconds(seconds).after(Emerald.Duration(nanoseconds: self.nanosecond))
        # The offsets a day either side. Clocks change at most once in that
        # span, so a repeated time has both, and a skipped time has neither.
        const before = zone.offset_at(Emerald.Instant.from_unix_seconds((seconds - 86400).clamp(-62135596800, 253402300799)))
        const after = zone.offset_at(Emerald.Instant.from_unix_seconds((seconds + 86400).clamp(-62135596800, 253402300799)))
        const earlier = naive.before(before)
        if zone.offset_at(earlier) == before {
            return earlier
        }
        const later = naive.before(after)
        if zone.offset_at(later) == after {
            return later
        }
        return earlier
    }

    # The difference the calendar and clock show, as if every day had exactly
    # 24 hours: a change of clocks in some time zone is not counted.
    func duration_until(other: Self): Emerald.Duration {
        const days = self.date.days_until(other.date)
        const seconds = (other.time.hour - self.time.hour) * 3600 + (other.time.minute - self.time.minute) * 60 + other.time.second - self.time.second
        return Emerald.Duration(seconds: days * 86400 + seconds, nanoseconds: other.time.nanosecond - self.time.nanosecond)
    }

    @override
    func compare(other: Self): Int {
        const by_date = self.date.compare(other.date)
        return if by_date != 0 then by_date else self.time.compare(other.time)
    }

    # YYYY-MM-DDTHH:MM:SS, the ISO 8601 form.
    @override
    func to_string(): String {
        return "#{self.date}T#{self.time}"
    }

    func DateTime._text_problem(text: String): String? {
        const points = text.trim().code_points()
        const shaped = points.count >= 16 and _date_shaped?(points, 0) and (points[10] == 84 or points[10] == 32) and _time_shaped?(points, 11, points.count)
        if not shaped {
            return "\"#{text}\" is not a date and time written as YYYY-MM-DDTHH:MM:SS, such as 2026-09-25T14:30:00"
        }
        const (year, month, day) = _date_at(points, 0)
        const (hour, minute, second, nanosecond) = _time_at(points, 11, points.count)
        var problem = _date_problem(year, month, day)
        if problem == nothing {
            problem = _time_problem(hour, minute, second, nanosecond)
        }
        if problem != nothing {
            return "\"#{text}\" is not a valid date and time: #{problem}"
        }
        return nothing
    }

    # Only after `_text_problem` has accepted the text.
    func DateTime._from_text(text: String): Emerald.DateTime {
        const points = text.trim().code_points()
        const (year, month, day) = _date_at(points, 0)
        const (hour, minute, second, nanosecond) = _time_at(points, 11, points.count)
        return Emerald.DateTime(year, month, day, hour, minute, second, nanosecond)
    }
}

# An exact moment, the same everywhere: whole seconds since
# 1970-01-01T00:00:00Z and a nanosecond part, within the years 1 through 9999.
struct Instant with Ordered, Textual {
    const _seconds: Int
    const _nanoseconds: Int

    func Instant.now(): Emerald.Instant {
        const now = Emerald.Instant._now()
        return Emerald.Instant._at(now // 1000000000, now % 1000000000)
    }

    # Native: nanoseconds since 1970-01-01T00:00:00Z on the system clock.
    func Instant._now(): Int {
        return 0
    }

    func Instant.from_unix_seconds(seconds: Int): Emerald.Instant {
        return Emerald.Instant._at(seconds, 0)
    }

    func Instant.from_unix_milliseconds(milliseconds: Int): Emerald.Instant {
        return Emerald.Instant._at(milliseconds // 1000, milliseconds % 1000 * 1000000)
    }

    func Instant.parse(text: String): Emerald.Instant {
        const problem = Emerald.Instant._text_problem(text)
        if problem != nothing {
            raise Emerald.DateTimeError(problem)
        }
        return Emerald.Instant._from_text(text)
    }

    func Instant.parse_maybe(text: String): Emerald.Instant? {
        if Emerald.Instant._text_problem(text) != nothing {
            return nothing
        }
        return Emerald.Instant._from_text(text)
    }

    # Rounded toward the past, as Unix time is.
    const unix_seconds: Int {
        return self._seconds
    }

    const unix_milliseconds: Int {
        return self._seconds * 1000 + self._nanoseconds // 1000000
    }

    @operator("+")
    func after(duration: Emerald.Duration): Emerald.Instant {
        const seconds = duration.whole_seconds
        const part = (duration - Emerald.Duration(seconds: seconds)).whole_nanoseconds
        return Emerald.Instant._at(self._seconds + seconds, self._nanoseconds + part)
    }

    @operator("-")
    func before(duration: Emerald.Duration): Emerald.Instant {
        return self.after(duration * -1)
    }

    # The exact time from `other` to this moment.
    @operator("-")
    func since(other: Self): Emerald.Duration {
        return Emerald.Duration(seconds: self._seconds - other._seconds, nanoseconds: self._nanoseconds - other._nanoseconds)
    }

    # What a calendar and clock in `zone` show at this moment.
    func to_date_time(zone: Emerald.TimeZone = Emerald.TimeZone.local): Emerald.DateTime {
        const local = self.after(zone.offset_at(self))
        const (year, month, day) = _civil_from_days(local._seconds // 86400)
        const second_of_day = local._seconds % 86400
        return Emerald.DateTime(year, month, day, second_of_day // 3600, second_of_day % 3600 // 60, second_of_day % 60, local._nanoseconds)
    }

    @override
    func compare(other: Self): Int {
        if self._seconds != other._seconds {
            return if self._seconds < other._seconds then -1 else 1
        }
        return self._nanoseconds - other._nanoseconds
    }

    # Always in UTC, marked with Z.
    @override
    func to_string(): String {
        return "#{self.to_date_time(Emerald.TimeZone.utc)}Z"
    }

    # The one way an Instant is built: normalized, and within the years 1
    # through 9999.
    func Instant._at(seconds: Int, nanoseconds: Int): Emerald.Instant {
        const whole = seconds + nanoseconds // 1000000000
        if whole < -62135596800 {
            raise Emerald.DateTimeError("this moment is before 0001-01-01T00:00:00Z, the earliest an Instant can be")
        }
        if whole > 253402300799 {
            raise Emerald.DateTimeError("this moment is after 9999-12-31T23:59:59.999999999Z, the latest an Instant can be")
        }
        return Emerald.Instant(whole, nanoseconds % 1000000000)
    }

    func Instant._text_problem(text: String): String? {
        const points = text.trim().code_points()
        const end = Emerald.Instant._time_end(points)
        const shaped = points.count >= 17 and _date_shaped?(points, 0) and (points[10] == 84 or points[10] == 32)
        if shaped and end == nothing and _time_shaped?(points, 11, points.count) {
            return "\"#{text}\" has no Z or offset, so it could be any moment: add Z for UTC, or read it with DateTime.parse"
        }
        if not shaped or end == nothing or not _time_shaped?(points, 11, end) {
            return "\"#{text}\" is not a moment written as YYYY-MM-DDTHH:MM:SS with Z or an offset, such as 2026-09-25T14:30:00Z"
        }
        const (year, month, day) = _date_at(points, 0)
        const (hour, minute, second, nanosecond) = _time_at(points, 11, end)
        var problem = _date_problem(year, month, day)
        if problem == nothing {
            problem = _time_problem(hour, minute, second, nanosecond)
        }
        if problem != nothing {
            return "\"#{text}\" is not a valid moment: #{problem}"
        }
        return nothing
    }

    # Where the time of day ends: before a final Z or a +HH:MM or -HH:MM
    # offset, or nothing when there is neither.
    func Instant._time_end(points: List[Int]): Int? {
        if points.count > 0 and points[points.count - 1] == 90 {
            return points.count - 1
        }
        if points.count >= 6 and _offset_at(points, points.count - 6) != nothing {
            return points.count - 6
        }
        return nothing
    }

    # Only after `_text_problem` has accepted the text.
    func Instant._from_text(text: String): Emerald.Instant {
        const points = text.trim().code_points()
        const end = Emerald.Instant._time_end(points).or(0)
        const (year, month, day) = _date_at(points, 0)
        const (hour, minute, second, nanosecond) = _time_at(points, 11, end)
        const offset = if end == points.count - 1 then 0 else _offset_at(points, end).or(0)
        const local = Emerald.DateTime(year, month, day, hour, minute, second, nanosecond)
        return local.to_instant(Emerald.TimeZone.utc).before(Emerald.Duration(seconds: offset))
    }
}

# The rules that turn an Instant into what a calendar and clock show in some
# place: UTC, a fixed offset from it such as "+05:30", a named IANA zone such
# as "Europe/Paris" from the database built into Emerald, or the machine's own
# zone.
struct TimeZone with Textual {
    const name: String
    # Whether the zone is always `_offset` seconds ahead of UTC; otherwise the
    # runtime holds rules for its name. Not an `Int?`, so a zone stays usable
    # as a dictionary key.
    const _fixed: Bool
    const _offset: Int

    const TimeZone.utc = Emerald.TimeZone("UTC")

    # The machine's zone, decided once when the program starts. UTC for
    # `emerald check`, tests of Emerald itself, and anywhere else no machine
    # zone was resolved.
    const TimeZone.local = Emerald.TimeZone(Emerald.TimeZone._local_name())

    constructor(name: String) {
        const offset = Emerald.TimeZone._fixed_offset(name)
        if offset == nothing and not Emerald.TimeZone._known?(name) {
            const suggestion = Emerald.TimeZone._suggestion(name)
            if suggestion != nothing {
                raise Emerald.DateTimeError("\"#{name}\" is not a time zone Emerald knows: zone names are case-sensitive, so write \"#{suggestion}\"")
            }
            raise Emerald.DateTimeError("\"#{name}\" is not a time zone Emerald knows: use an IANA name such as \"Europe/Paris\", \"UTC\", or an offset such as \"+05:30\"")
        }
        self.name = name
        self._fixed = offset != nothing
        self._offset = offset.or(0)
    }

    # The zone called `name`, or nothing when there is none.
    func TimeZone.named_maybe(name: String): Emerald.TimeZone? {
        if Emerald.TimeZone._fixed_offset(name) == nothing and not Emerald.TimeZone._known?(name) {
            return nothing
        }
        return Emerald.TimeZone(name)
    }

    # A zone always this far from UTC, named like "+05:30" or "-03:30". The
    # minutes take the sign of the hours.
    func TimeZone.fixed(hours: Int, minutes: Int = 0): Emerald.TimeZone {
        if minutes < -59 or minutes > 59 or (hours > 0 and minutes < 0) or (hours < 0 and minutes > 0) {
            raise Emerald.DateTimeError("minutes #{minutes} must be between -59 and 59, with the same sign as hours #{hours}: write minutes: #{-minutes} instead")
        }
        const total = (hours * 60 + minutes).abs()
        if total > 18 * 60 {
            raise Emerald.DateTimeError("an offset of #{hours} hours is not between -18 and 18")
        }
        const sign = if hours < 0 or minutes < 0 then "-" else "+"
        return Emerald.TimeZone("#{sign}#{_two_digits(total // 60)}:#{_two_digits(total % 60)}")
    }

    # How far ahead of UTC clocks in this zone are at `instant`.
    func offset_at(instant: Emerald.Instant): Emerald.Duration {
        if self._fixed {
            return Emerald.Duration(seconds: self._offset)
        }
        return Emerald.Duration(seconds: Emerald.TimeZone._offset_seconds(self.name, instant.unix_seconds))
    }

    @override
    func to_string(): String {
        return self.name
    }

    func TimeZone._fixed_offset(name: String): Int? {
        if name == "UTC" {
            return 0
        }
        return _offset_at(name.code_points(), 0)
    }

    # Native: the name of the zone the runtime resolved for this execution.
    func TimeZone._local_name(): String {
        return "UTC"
    }

    # Native: whether the runtime holds rules for a zone of this name.
    func TimeZone._known?(name: String): Bool {
        return false
    }

    # Native: the zone name meant by one written in the wrong case.
    func TimeZone._suggestion(name: String): String? {
        return nothing
    }

    # Native: the offset in seconds that a rule-based zone has at a moment
    # given in Unix seconds.
    func TimeZone._offset_seconds(name: String, unix_seconds: Int): Int {
        return 0
    }
}

# Measures elapsed time on the monotonic clock, which a change to the system
# clock cannot move.
class Stopwatch with Textual {
    var _started: Int

    func Stopwatch.start(): Emerald.Stopwatch {
        return Emerald.Stopwatch(Emerald.Stopwatch._ticks())
    }

    # Native: nanoseconds on the monotonic clock, from an unspecified start.
    func Stopwatch._ticks(): Int {
        return 0
    }

    func elapsed(): Emerald.Duration {
        return Emerald.Duration(nanoseconds: Emerald.Stopwatch._ticks() - self._started)
    }

    func restart() {
        self._started = Emerald.Stopwatch._ticks()
    }

    @override
    func to_string(): String {
        return "Stopwatch(#{self.elapsed()})"
    }
}

# Regular expressions (15.4). The matching engine is native (src/Regex.zig):
# a pattern takes time in proportion to the text, whatever it is. What is here
# gives it named options, validation, and display, over positional natives that
# take the pattern and options each time; the runtime caches each compiled
# pattern, so building the same Regex again costs nothing.

# A pattern that cannot be compiled, or a group a match does not have. The
# message quotes the pattern and gives the position of the problem in it.
class RegexError extends RuntimeError {
    constructor(message: String) {
        super(message)
    }
}

struct Regex with Textual {
    const pattern: String
    const ignore_case: Bool
    const multiline: Bool

    # One match, found in some text. `start` and `end` count characters as
    # indexing does, so `text[found.start..<found.end]` is `found.text`.
    struct Match with Textual {
        const text: String
        const start: Int
        const end: Int
        # Every group, group 0 (the whole match) first: where each starts and
        # ends, -1 for a group that took no part, and its text.
        const _spans: List[Int]
        const _texts: List[String]
        # Each group's name, or "" for a group without one.
        const _names: List[String]
        # The pattern that found it, for messages.
        const _pattern: String

        # Group `number`'s text, where group 0 is the whole match and the
        # others count opening parentheses from the left. A RegexError when
        # the group took no part in this match, as `(x)?` without an x.
        func group(number: Int): String {
            const text = self.group_maybe(number)
            if text == nothing {
                raise Emerald.RegexError("group #{number} of the pattern \"#{self._pattern}\" took no part in this match; use group_maybe(#{number}) to get nothing instead")
            }
            return text
        }

        # Group `number`'s text, or nothing when it took no part in this match.
        func group_maybe(number: Int): String? {
            if number < 0 or number >= self._texts.count {
                const groups = if self._texts.count == 1 then "its only group is 0, the whole match" else "its groups are numbered 0 to #{self._texts.count - 1}, where 0 is the whole match"
                raise Emerald.RegexError("the pattern \"#{self._pattern}\" has no group #{number}: #{groups}")
            }
            if self._spans[2 * number] < 0 {
                return nothing
            }
            return self._texts[number]
        }

        # The text of the group written (?<name>...). A RegexError when it
        # took no part in this match.
        func named(name: String): String {
            const text = self.named_maybe(name)
            if text == nothing {
                raise Emerald.RegexError("the group named \"#{name}\" in the pattern \"#{self._pattern}\" took no part in this match; use named_maybe(\"#{name}\") to get nothing instead")
            }
            return text
        }

        # The text of the group written (?<name>...), or nothing when it took
        # no part in this match.
        func named_maybe(name: String): String? {
            const number = if name == "" then nothing else self._names.find_index { each => each == name }
            if number == nothing {
                raise Emerald.RegexError("the pattern \"#{self._pattern}\" has no group named \"#{name}\": #{self._named_groups()}")
            }
            return self.group_maybe(number)
        }

        func _named_groups(): String {
            const names = self._names.filter { each => each != "" }
            if names.count == 0 {
                return "it has no named groups; write (?<name>...) to name one"
            }
            var listed = "\"#{names[0]}\""
            for index in 1..<names.count {
                listed += if index == names.count - 1 then " and \"#{names[index]}\"" else ", \"#{names[index]}\""
            }
            return if names.count == 1 then "its one named group is #{listed}" else "its named groups are #{listed}"
        }

        @override
        func to_string(): String {
            return "Regex.Match(\"#{self.text}\" at #{self.start}..<#{self.end})"
        }
    }

    constructor(pattern: String, ignore_case: Bool = false, multiline: Bool = false) {
        const problem = Emerald.Regex._problem(pattern, ignore_case, multiline)
        if problem != nothing {
            raise Emerald.RegexError(problem)
        }
        self.pattern = pattern
        self.ignore_case = ignore_case
        self.multiline = multiline
    }

    # Native: a pattern that matches `text` and nothing else, every character
    # with a meaning in patterns written with a backslash.
    func Regex.escape(text: String): String {
        return text
    }

    # Whether the whole of `text` matches.
    func matches?(text: String): Bool {
        return Emerald.Regex._whole?(self.pattern, self.ignore_case, self.multiline, text)
    }

    # Whether some part of `text` matches.
    func contains_match?(text: String): Bool {
        return Emerald.Regex._find(self.pattern, self.ignore_case, self.multiline, text, 1).count > 0
    }

    # The first match in `text`, or nothing.
    func find(text: String): Emerald.Regex.Match? {
        const found = Emerald.Regex._find(self.pattern, self.ignore_case, self.multiline, text, 1)
        if found.count == 0 {
            return nothing
        }
        return found[0]
    }

    # Every match in `text`, from left to right, none overlapping.
    func find_all(text: String): List[Emerald.Regex.Match] {
        return Emerald.Regex._find(self.pattern, self.ignore_case, self.multiline, text, 0)
    }

    # `text` with its first match replaced. The replacement is used as it is
    # written: "$1" is a dollar sign and a one.
    func replace(text: String, replacement: String): String {
        return Emerald.Regex._replace(self.pattern, self.ignore_case, self.multiline, text, replacement, 1)
    }

    # `text` with every match replaced, the replacement used as it is written.
    func replace_all(text: String, replacement: String): String {
        return Emerald.Regex._replace(self.pattern, self.ignore_case, self.multiline, text, replacement, 0)
    }

    # `text` with every match replaced by what `block` returns for it.
    func replace_each(text: String, block: func(Emerald.Regex.Match): String): String {
        const found = self.find_all(text)
        return Emerald.Regex._splice(text, found, found.map { each => block(each) })
    }

    # The pieces of `text` between matches, empty pieces included, as
    # String.split keeps them. A match of nothing at the very start or end
    # splits nothing off, so a pattern that matches nothing splits between
    # every character.
    func split(text: String): List[String] {
        return Emerald.Regex._split(self.pattern, self.ignore_case, self.multiline, text)
    }

    @override
    func to_string(): String {
        return self.pattern
    }

    # Native: why the pattern cannot be compiled, or nothing when it can.
    func Regex._problem(pattern: String, ignore_case: Bool, multiline: Bool): String? {
        return nothing
    }

    # Native: whether the whole text matches.
    func Regex._whole?(pattern: String, ignore_case: Bool, multiline: Bool, text: String): Bool {
        return false
    }

    # Native: the matches in `text` from left to right, at most `limit` of
    # them, or all of them when `limit` is 0.
    func Regex._find(pattern: String, ignore_case: Bool, multiline: Bool, text: String, limit: Int): List[Emerald.Regex.Match] {
        return []
    }

    # Native: `text` with at most `limit` matches replaced, or all of them
    # when `limit` is 0.
    func Regex._replace(pattern: String, ignore_case: Bool, multiline: Bool, text: String, replacement: String, limit: Int): String {
        return text
    }

    # Native: the pieces of `text` between matches.
    func Regex._split(pattern: String, ignore_case: Bool, multiline: Bool, text: String): List[String] {
        return []
    }

    # Native: `text` with each match replaced by the replacement at the same
    # position.
    func Regex._splice(text: String, found: List[Emerald.Regex.Match], replacements: List[String]): String {
        return text
    }
}
