//! Section 15.7's JSON: a strict RFC 8259 parser and writer, without any
//! Emerald-facing type yet (docs/json-design-plan.md, slice 1). The parser is
//! one pass and iterative: an explicit stack of open containers stands in
//! for recursion, so nesting depth is checked directly rather than by
//! however deep Zig's own call stack happens to go, the same way `Regex`'s
//! own matcher uses an explicit stack instead of recursion. Every mistake
//! gets its own message: a trailing comma, single quotes, an unquoted key, a
//! comment, `NaN`, or a string that never closes.
//!
//! A parsed document owns every byte it needs (strings are always copied and
//! escapes resolved), so it outlives the text it was parsed from, the same
//! way a compiled `Regex.Program` outlives the pattern text. Positions are
//! one-based lines and Unicode scalar-value columns, the same counting
//! `Source.Location` uses for Emerald's own diagnostics.
//!
//! Numbers keep both an exact `Int` interpretation, when the text has no
//! fractional part and fits in 64 bits, and a `Float` interpretation, always:
//! `3`, `3.0`, and `3e2` all carry `is_integer = true`. Writing a value always
//! produces its canonical text (matching `Value.displayFloat`'s shortest
//! round-trip form for a `Float`), never the original source spelling, so
//! `Json.encode` after `Json.parse` is predictable rather than a surprise
//! preservation of whatever whitespace or digits someone typed.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The most nested objects and arrays may go, so a deliberately broken or
/// malicious document cannot exhaust memory or the parser's stack.
pub const max_depth = 512;

pub const ParseError = Allocator.Error || error{InvalidJson};

/// Why a document was refused, and where. `line` and `column` are one-based;
/// `column` counts Unicode scalar values, as `Source.Location` does. The
/// message does not repeat the position; the caller adds that.
pub const Problem = struct {
    line: u32 = 1,
    column: u32 = 1,
    buffer: [400]u8 = undefined,
    length: usize = 0,

    pub fn message(self: *const Problem) []const u8 {
        return self.buffer[0..self.length];
    }

    fn fail(self: *Problem, position: Position, comptime format: []const u8, arguments: anytype) error{InvalidJson} {
        self.line = position.line;
        self.column = position.column;
        const written: []const u8 = std.fmt.bufPrint(&self.buffer, format, arguments) catch &self.buffer;
        self.length = written.len;
        return error.InvalidJson;
    }
};

// Values.

pub const Kind = enum { null, bool, number, string, list, object };

/// One key and its value, in the order the object was written or built.
pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// A JSON value, fully in memory: every string decoded, every number read
/// both ways, every container's children built. Everything a `Value` points
/// to lives in its `Document`'s arena.
pub const Value = struct {
    kind: Kind = .null,
    bool_value: bool = false,
    /// For `kind == .number`: whether the number has no fractional part and
    /// fits in `Int`, so `3`, `3.0`, and `3e2` all read this way, but `3.5`
    /// and a number too large for `Int` do not.
    is_integer: bool = false,
    int_value: i64 = 0,
    /// For `kind == .number`, always: a best-effort `Float` reading, which is
    /// `Infinity` or `-Infinity` for a magnitude too large for one, per
    /// IEEE 754. Precision beyond a `Float`'s is not preserved.
    float_value: f64 = 0,
    /// For the writer only: whether to write this number with a decimal
    /// point or exponent. True for a number written or built with one
    /// (`3.0`, `3e2`, `Json.from_float`), even when it is mathematically
    /// whole, so a `Float` stays visibly a `Float` on the way back out;
    /// false for a bare integer (`3`, `Json.from_int`).
    is_float_literal: bool = false,
    string_value: []const u8 = "",
    items: []Value = &.{},
    entries: []Entry = &.{},

    pub fn initNull() Value {
        return .{ .kind = .null };
    }

    pub fn initBool(value: bool) Value {
        return .{ .kind = .bool, .bool_value = value };
    }

    pub fn initInt(value: i64) Value {
        return .{ .kind = .number, .is_integer = true, .int_value = value, .float_value = @floatFromInt(value), .is_float_literal = false };
    }

    /// A number from a `Float`. Whether it counts as a whole number for
    /// `int()` follows the same rule numbers read from text do: no
    /// fractional part, and within `Int`'s range; it always writes back
    /// with a decimal point or exponent, since it came from a `Float`.
    pub fn initFloat(value: f64) Value {
        var result: Value = .{ .kind = .number, .float_value = value, .is_float_literal = true };
        if (std.math.isFinite(value) and value == @trunc(value) and value >= min_exact_int and value <= max_exact_int) {
            result.is_integer = true;
            result.int_value = @intFromFloat(value);
        }
        return result;
    }

    /// `text` must already be owned by the document's arena (or live at
    /// least as long as it).
    pub fn initString(text: []const u8) Value {
        return .{ .kind = .string, .string_value = text };
    }

    pub fn initList(items: []Value) Value {
        return .{ .kind = .list, .items = items };
    }

    /// `entries` must already have had its keys checked for duplicates;
    /// `parse` does this itself, but a caller building a value directly
    /// (as the typed encoder will) is responsible for it.
    pub fn initObject(entries: []Entry) Value {
        return .{ .kind = .object, .entries = entries };
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self.kind != .object) return null;
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// -2^63 and 2^63 - 1, the smallest and largest exact `f64` values at or
/// within `Int`'s range: `Int`'s own bounds are not exactly representable as
/// `f64`, so the comparison uses the nearest values that are.
const min_exact_int: f64 = -9223372036854775808.0;
const max_exact_int: f64 = 9223372036854775807.0;

/// A parsed document: its root value, and the arena everything it points to
/// lives in.
pub const Document = struct {
    arena_state: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void {
        self.arena_state.deinit();
    }
};

// Parsing.

const Position = struct { line: u32 = 1, column: u32 = 1 };

/// A byte-order mark, which Emerald's own source reading silently drops
/// (`Source.stripByteOrderMark`); JSON text gets the same courtesy, since a
/// text editor can add one without anyone asking for it.
fn stripByteOrderMark(bytes: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
}

pub fn parse(gpa: Allocator, text: []const u8, problem: *Problem) ParseError!Document {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser: Parser = .{ .arena = arena, .text = stripByteOrderMark(text), .problem = problem };
    const root = try parser.parseDocument();
    return .{ .arena_state = arena_state, .root = root };
}

/// What a container currently open on the frame stack is waiting for next.
const Next = enum { value, value_or_close, comma_or_close, key, key_or_close, colon };

const Frame = struct {
    kind: enum { list, object },
    next: Next,
    items: std.ArrayList(Value) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    pending_key: ?[]const u8 = null,

    fn hasKey(self: *const Frame, key: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return true;
        }
        return false;
    }
};

/// Whether delivering a completed value finished the document (there was
/// nowhere left to put it) or was appended into the container now on top of
/// the stack.
const Delivery = enum { root, more };

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    problem: *Problem,
    at: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    stack: std.ArrayList(Frame) = .empty,

    fn position(self: *const Parser) Position {
        return .{ .line = self.line, .column = self.column };
    }

    fn atEnd(self: *const Parser) bool {
        return self.at >= self.text.len;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.atEnd()) null else self.text[self.at];
    }

    fn peekAt(self: *const Parser, offset: usize) ?u8 {
        const index = self.at + offset;
        return if (index >= self.text.len) null else self.text[index];
    }

    /// Advances by one codepoint, ASCII or not; every JSON structural
    /// character and every escape marker is ASCII, so callers that only test
    /// for those may still call this once per codepoint uniformly.
    fn advance(self: *Parser) void {
        if (self.atEnd()) return;
        const length = std.unicode.utf8ByteSequenceLength(self.text[self.at]) catch 1;
        const clamped = @min(length, self.text.len - self.at);
        if (self.text[self.at] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.at += clamped;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r' => self.advance(),
                else => return,
            }
        }
    }

    fn fail(self: *Parser, position_: Position, comptime format: []const u8, arguments: anytype) error{InvalidJson} {
        return self.problem.fail(position_, format, arguments);
    }

    /// The whole document: repeatedly advances whichever container is
    /// currently open (or, with none open, reads the root value itself) by
    /// exactly one step, delivering each value `step` completes to its
    /// parent until nothing is left open, and then requires the rest of the
    /// text to be only whitespace.
    fn parseDocument(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        if (self.atEnd()) return self.fail(self.position(), "the document is empty", .{});

        while (true) {
            const value = try self.step() orelse continue;
            switch (try self.deliver(value)) {
                .root => {
                    self.skipWhitespace();
                    if (!self.atEnd()) {
                        return self.fail(self.position(), "the document has more after this value; JSON allows only one value", .{});
                    }
                    return value;
                },
                .more => {},
            }
        }
    }

    /// Makes exactly one unit of progress: reading a value with nothing open
    /// yet, advancing the frame on top of the stack past whatever it is
    /// waiting for, or closing that frame. Returns the value just completed,
    /// if any; every other kind of progress (recording a key, consuming a
    /// `:` or `,`, opening a frame) returns null and leaves the caller to
    /// call `step` again.
    fn step(self: *Parser) ParseError!?Value {
        if (self.stack.items.len == 0) return try self.readValueOrOpen();
        const frame = &self.stack.items[self.stack.items.len - 1];
        switch (frame.next) {
            .value, .value_or_close => {
                self.skipWhitespace();
                if (frame.kind == .list and self.peek() == ']') {
                    if (frame.next == .value_or_close) {
                        self.advance();
                        return try self.closeList(frame);
                    }
                    // `.next == .value`: this list just consumed a comma, so
                    // an immediate close is the same mistake `failBadKey`
                    // names for an object.
                    return self.fail(self.position(), "JSON does not allow a comma before \"]\"", .{});
                }
                return try self.readValueOrOpen();
            },
            .key_or_close, .key => {
                self.skipWhitespace();
                if (frame.next == .key_or_close and self.peek() == '}') {
                    self.advance();
                    return try self.closeObject(frame);
                }
                const key_position = self.position();
                if (self.peek() != '"') return self.failBadKey(frame, key_position);
                const key = try self.readStringLiteral();
                if (frame.hasKey(key)) {
                    return self.fail(key_position, "the key \"{s}\" is already used in this object", .{key});
                }
                frame.pending_key = key;
                frame.next = .colon;
                return null;
            },
            .colon => {
                self.skipWhitespace();
                if (self.peek() != ':') return self.fail(self.position(), "expected \":\" after this key", .{});
                self.advance();
                frame.next = .value;
                return null;
            },
            .comma_or_close => {
                self.skipWhitespace();
                const close: u8 = if (frame.kind == .list) ']' else '}';
                if (self.peek() == close) {
                    self.advance();
                    return if (frame.kind == .list) try self.closeList(frame) else try self.closeObject(frame);
                }
                if (self.peek() != ',') {
                    const close_name = if (frame.kind == .list) "\"]\"" else "\"}\"";
                    return self.fail(self.position(), "expected \",\" or {s} after this value", .{close_name});
                }
                self.advance();
                frame.next = if (frame.kind == .list) .value else .key;
                return null;
            },
        }
    }

    fn closeList(self: *Parser, frame: *Frame) ParseError!Value {
        const items = try frame.items.toOwnedSlice(self.arena);
        self.stack.items.len -= 1;
        return .initList(items);
    }

    fn closeObject(self: *Parser, frame: *Frame) ParseError!Value {
        const entries = try frame.entries.toOwnedSlice(self.arena);
        self.stack.items.len -= 1;
        return .initObject(entries);
    }

    /// A trailing comma before `}` reaches here as `.next == .key` finding
    /// no opening quote; a bare identifier used as an unquoted key gets its
    /// own message with the word it found.
    fn failBadKey(self: *Parser, frame: *const Frame, position_: Position) error{InvalidJson} {
        if (frame.next == .key and self.peek() == '}') {
            return self.fail(position_, "JSON does not allow a comma before \"}}\"", .{});
        }
        if (self.identifierAhead()) |word| {
            return self.fail(position_, "JSON object keys need double quotes: write \"{s}\"", .{word});
        }
        if (self.peek() == '\'') return self.fail(position_, "JSON strings use double quotes, not single quotes", .{});
        return self.fail(position_, "expected a key in double quotes here", .{});
    }

    /// Delivers a completed value (a scalar, or a container that just
    /// closed) to whatever is waiting for it: the enclosing list, the
    /// enclosing object's pending key, or nowhere, meaning it is the root.
    fn deliver(self: *Parser, value: Value) ParseError!Delivery {
        if (self.stack.items.len == 0) return .root;
        const frame = &self.stack.items[self.stack.items.len - 1];
        if (frame.kind == .list) {
            try frame.items.append(self.arena, value);
        } else {
            try frame.entries.append(self.arena, .{ .key = frame.pending_key.?, .value = value });
            frame.pending_key = null;
        }
        frame.next = .comma_or_close;
        return .more;
    }

    /// Reads one value where a value is expected: a scalar token becomes a
    /// `Value` directly; `{` or `[` pushes a new frame and returns null, so
    /// depth lives entirely in `self.stack` rather than in how deep this
    /// function has called itself.
    fn readValueOrOpen(self: *Parser) ParseError!?Value {
        self.skipWhitespace();
        const start = self.position();
        const byte = self.peek() orelse return self.fail(start, "the document ends where a value was expected", .{});
        switch (byte) {
            '{' => {
                if (self.stack.items.len >= max_depth) return self.failTooDeep(start);
                self.advance();
                try self.stack.append(self.arena, .{ .kind = .object, .next = .key_or_close });
                return null;
            },
            '[' => {
                if (self.stack.items.len >= max_depth) return self.failTooDeep(start);
                self.advance();
                try self.stack.append(self.arena, .{ .kind = .list, .next = .value_or_close });
                return null;
            },
            '"' => return .initString(try self.readStringLiteral()),
            '-', '.', '0'...'9' => return try self.readNumber(start),
            't' => return try self.readKeyword("true", .initBool(true), start),
            'f' => return try self.readKeyword("false", .initBool(false), start),
            'n' => return try self.readKeyword("null", .initNull(), start),
            'N' => {
                if (self.identifierAhead()) |word| if (std.mem.eql(u8, word, "NaN")) {
                    self.skipIdentifier();
                    return self.fail(start, "NaN is not a JSON number", .{});
                };
                return self.failNotAValue(start);
            },
            'I' => {
                if (self.identifierAhead()) |word| if (std.mem.eql(u8, word, "Infinity")) {
                    self.skipIdentifier();
                    return self.fail(start, "Infinity is not a JSON number", .{});
                };
                return self.failNotAValue(start);
            },
            '\'' => return self.fail(start, "JSON strings use double quotes, not single quotes", .{}),
            '/' => {
                if (self.peekAt(1) == '/' or self.peekAt(1) == '*') return self.fail(start, "JSON has no comments", .{});
                return self.failNotAValue(start);
            },
            else => return self.failNotAValue(start),
        }
    }

    /// The current byte (or identifier-shaped run starting there) does not
    /// start a value; names it in the message when it is safe to (an
    /// identifier, or one more character), or falls back to a plain
    /// end-of-document message when there is nothing left to name.
    fn failNotAValue(self: *Parser, start: Position) error{InvalidJson} {
        if (self.identifierAhead()) |word| {
            self.skipIdentifier();
            return self.fail(start, "\"{s}\" is not a JSON value", .{word});
        }
        const byte = self.peek() orelse return self.fail(start, "the document ends where a value was expected", .{});
        self.advance();
        return self.fail(start, "\"{c}\" here does not start a value: JSON values are an object, an array, a string, a number, true, false, or null", .{byte});
    }

    fn failTooDeep(self: *Parser, position_: Position) error{InvalidJson} {
        return self.fail(position_, "this document is nested more than {d} levels deep", .{max_depth});
    }

    /// The identifier-shaped run of letters, digits, and underscores at the
    /// current position, without consuming it, or null when the current
    /// byte does not start one.
    fn identifierAhead(self: *const Parser) ?[]const u8 {
        if (!isIdentifierStart(self.peek() orelse return null)) return null;
        var end = self.at + 1;
        while (end < self.text.len and isIdentifierContinue(self.text[end])) end += 1;
        return self.text[self.at..end];
    }

    fn skipIdentifier(self: *Parser) void {
        while (self.peek()) |byte| {
            if (!isIdentifierContinue(byte)) return;
            self.advance();
        }
    }

    fn isIdentifierStart(byte: u8) bool {
        return std.ascii.isAlphabetic(byte) or byte == '_';
    }

    fn isIdentifierContinue(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }

    /// `keyword` (`"true"`, `"false"`, or `"null"`) at `start`, already known
    /// to begin with the right first letter.
    fn readKeyword(self: *Parser, keyword: []const u8, value: Value, start: Position) ParseError!Value {
        if (self.text.len - self.at >= keyword.len and std.mem.eql(u8, self.text[self.at..][0..keyword.len], keyword)) {
            const after = self.at + keyword.len;
            if (after >= self.text.len or !isIdentifierContinue(self.text[after])) {
                for (0..keyword.len) |_| self.advance();
                return value;
            }
        }
        return self.failNotAValue(start);
    }

    // Strings.

    fn readStringLiteral(self: *Parser) ParseError![]const u8 {
        const start = self.position();
        self.advance(); // the opening quote
        var built: std.ArrayList(u8) = .empty;
        while (true) {
            const byte = self.peek() orelse return self.fail(start, "this text ends inside a string that started at line {d}, column {d}", .{ start.line, start.column });
            if (byte == '"') {
                self.advance();
                return try built.toOwnedSlice(self.arena);
            }
            if (byte == '\\') {
                try self.readEscape(&built);
                continue;
            }
            if (byte < 0x20) {
                return self.fail(self.position(), "a string cannot contain this control character unescaped; write \\n, \\t, or \\u{{{X:0>4}}}", .{byte});
            }
            const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const clamped = @min(length, self.text.len - self.at);
            try built.appendSlice(self.arena, self.text[self.at..][0..clamped]);
            self.advance();
        }
    }

    fn readEscape(self: *Parser, built: *std.ArrayList(u8)) ParseError!void {
        const backslash_at = self.position();
        self.advance(); // the backslash
        const letter = self.peek() orelse return self.fail(backslash_at, "a pattern cannot end with a single backslash", .{});
        switch (letter) {
            '"' => try appendByte(built, self.arena, '"'),
            '\\' => try appendByte(built, self.arena, '\\'),
            '/' => try appendByte(built, self.arena, '/'),
            'b' => try appendByte(built, self.arena, 0x08),
            'f' => try appendByte(built, self.arena, 0x0C),
            'n' => try appendByte(built, self.arena, '\n'),
            'r' => try appendByte(built, self.arena, '\r'),
            't' => try appendByte(built, self.arena, '\t'),
            'u' => return try self.readUnicodeEscape(built, backslash_at),
            else => return self.fail(backslash_at, "\"\\{c}\" is not a JSON escape; use \\\", \\\\, \\/, \\b, \\f, \\n, \\r, \\t, or \\u", .{letter}),
        }
        self.advance();
    }

    fn readUnicodeEscape(self: *Parser, built: *std.ArrayList(u8), backslash_at: Position) ParseError!void {
        self.advance(); // the "u"
        const first = try self.readHex4(backslash_at);
        if (first >= 0xD800 and first <= 0xDBFF) {
            // A high surrogate: the next escape must be its low half.
            if (self.peek() == '\\' and self.peekAt(1) == 'u') {
                const save_at = self.at;
                const save_line = self.line;
                const save_column = self.column;
                self.advance();
                self.advance();
                const second = try self.readHex4(backslash_at);
                if (second >= 0xDC00 and second <= 0xDFFF) {
                    const code_point: u21 = 0x10000 + (@as(u21, first) - 0xD800) * 0x400 + (@as(u21, second) - 0xDC00);
                    return try appendCodePoint(built, self.arena, code_point);
                }
                self.at = save_at;
                self.line = save_line;
                self.column = save_column;
            }
            return self.fail(backslash_at, "a \"\\u\" escape here names half of a surrogate pair without the other half", .{});
        }
        if (first >= 0xDC00 and first <= 0xDFFF) {
            return self.fail(backslash_at, "a \"\\u\" escape here names half of a surrogate pair without the other half", .{});
        }
        try appendCodePoint(built, self.arena, first);
    }

    fn readHex4(self: *Parser, backslash_at: Position) ParseError!u16 {
        var value: u16 = 0;
        for (0..4) |_| {
            const byte = self.peek() orelse return self.fail(backslash_at, "a \"\\u\" escape needs four hex digits", .{});
            if (!std.ascii.isHex(byte)) return self.fail(backslash_at, "a \"\\u\" escape needs four hex digits", .{});
            value = value * 16 + (std.fmt.charToDigit(byte, 16) catch unreachable);
            self.advance();
        }
        return value;
    }

    // Numbers.

    fn readNumber(self: *Parser, start: Position) ParseError!Value {
        const begin = self.at;
        var negative = false;
        if (self.peek() == '-') {
            negative = true;
            self.advance();
        }
        if (negative) {
            if (self.identifierAhead()) |word| {
                self.skipIdentifier();
                if (std.mem.eql(u8, word, "Infinity")) return self.fail(start, "-Infinity is not a JSON number", .{});
                return self.fail(start, "\"-{s}\" is not a JSON value", .{word});
            }
        }
        if (self.peek() == '.') return self.fail(self.position(), "a number needs a digit before the decimal point; write 0.5", .{});
        const first_digit = self.peek() orelse 0;
        if (!std.ascii.isDigit(first_digit)) {
            self.at = begin;
            return self.failNotAValue(start);
        }
        if (first_digit == '0' and std.ascii.isDigit(self.peekAt(1) orelse 0)) {
            return self.fail(self.position(), "a number cannot have a leading zero", .{});
        }
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            self.advance();
        }
        var saw_fraction_or_exponent = false;
        if (self.peek() == '.') {
            saw_fraction_or_exponent = true;
            self.advance();
            if (!std.ascii.isDigit(self.peek() orelse 0)) return self.fail(self.position(), "a number needs a digit after the decimal point", .{});
            while (self.peek()) |byte| {
                if (!std.ascii.isDigit(byte)) break;
                self.advance();
            }
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            saw_fraction_or_exponent = true;
            self.advance();
            if (self.peek() == '+' or self.peek() == '-') self.advance();
            if (!std.ascii.isDigit(self.peek() orelse 0)) return self.fail(self.position(), "a number needs a digit in its exponent", .{});
            while (self.peek()) |byte| {
                if (!std.ascii.isDigit(byte)) break;
                self.advance();
            }
        }
        const text = self.text[begin..self.at];
        const float_value = std.fmt.parseFloat(f64, text) catch unreachable;
        if (!saw_fraction_or_exponent) {
            // A bare integer as written ("123", "-45"). Kept in that shape
            // for writing even when it is too large for `Int`, in which
            // case `int()`'s own rule (via `initFloat`) decides whether it
            // still counts as a whole number.
            if (std.fmt.parseInt(i64, text, 10)) |exact| {
                return .{ .kind = .number, .is_integer = true, .int_value = exact, .float_value = float_value, .is_float_literal = false };
            } else |_| {
                var too_big = Value.initFloat(float_value);
                too_big.is_float_literal = false;
                return too_big;
            }
        }
        // A decimal point or exponent was written ("3.0", "3e2"): `int()`'s
        // rule still may or may not accept it, but writing always keeps it
        // visibly a Float-shaped number.
        return .initFloat(float_value);
    }
};

fn appendByte(list: *std.ArrayList(u8), arena: Allocator, byte: u8) Allocator.Error!void {
    try list.append(arena, byte);
}

fn appendCodePoint(list: *std.ArrayList(u8), arena: Allocator, code_point: u21) Allocator.Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
    try list.appendSlice(arena, buffer[0..length]);
}

// Writing.

pub const WriteOptions = struct { pretty: bool = false };

pub const WriteError = std.Io.Writer.Error || error{NonFiniteNumber};

/// Writes `value` as JSON text: compact (no whitespace at all) unless
/// `options.pretty`, which uses two-space indentation and one entry per
/// line. Always the canonical form (see the file's own doc comment), never
/// whatever text a number or string was originally parsed from.
pub fn write(value: Value, options: WriteOptions, out: *std.Io.Writer) WriteError!void {
    var writer: Writer = .{ .options = options, .out = out };
    try writer.writeValue(value, 0);
}

const Writer = struct {
    options: WriteOptions,
    out: *std.Io.Writer,

    fn writeValue(self: *Writer, value: Value, depth: u32) WriteError!void {
        switch (value.kind) {
            .null => try self.out.writeAll("null"),
            .bool => try self.out.writeAll(if (value.bool_value) "true" else "false"),
            .number => try self.writeNumber(value),
            .string => try writeString(value.string_value, self.out),
            .list => try self.writeList(value.items, depth),
            .object => try self.writeObject(value.entries, depth),
        }
    }

    fn writeNumber(self: *Writer, value: Value) WriteError!void {
        if (!value.is_float_literal and value.is_integer) {
            try self.out.print("{d}", .{value.int_value});
            return;
        }
        if (!std.math.isFinite(value.float_value)) return error.NonFiniteNumber;
        try writeFiniteFloat(value.float_value, self.out);
    }

    fn writeList(self: *Writer, items: []const Value, depth: u32) WriteError!void {
        if (items.len == 0) return self.out.writeAll("[]");
        try self.out.writeByte('[');
        for (items, 0..) |item, index| {
            if (index > 0) try self.out.writeByte(',');
            try self.newlineAndIndent(depth + 1);
            try self.writeValue(item, depth + 1);
        }
        try self.newlineAndIndent(depth);
        try self.out.writeByte(']');
    }

    fn writeObject(self: *Writer, entries: []const Entry, depth: u32) WriteError!void {
        if (entries.len == 0) return self.out.writeAll("{}");
        try self.out.writeByte('{');
        for (entries, 0..) |entry, index| {
            if (index > 0) try self.out.writeByte(',');
            try self.newlineAndIndent(depth + 1);
            try writeString(entry.key, self.out);
            try self.out.writeByte(':');
            if (self.options.pretty) try self.out.writeByte(' ');
            try self.writeValue(entry.value, depth + 1);
        }
        try self.newlineAndIndent(depth);
        try self.out.writeByte('}');
    }

    fn newlineAndIndent(self: *Writer, depth: u32) WriteError!void {
        if (!self.options.pretty) return;
        try self.out.writeByte('\n');
        try self.out.splatByteAll(' ', depth * 2);
    }
};

fn writeString(text: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeByte('"');
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        switch (byte) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x08 => try out.writeAll("\\b"),
            0x0C => try out.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try out.print("\\u{X:0>4}", .{byte});
                } else {
                    try out.writeByte(byte);
                }
            },
        }
        index += 1;
    }
    try out.writeByte('"');
}

/// Section 9.4's rules for a `Float`'s shortest round-tripping text, and the
/// same fixed/scientific threshold `Value.displayFloat` uses, without its
/// `NaN`/`Infinity` spellings: those are not valid JSON, so `write` returns
/// `error.NonFiniteNumber` before this is ever called for them.
fn writeFiniteFloat(value: f64, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (usesScientificNotation(value)) return writeScientific(value, out);
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try out.writeAll(text);
    if (std.mem.indexOfScalar(u8, text, '.') == null) try out.writeAll(".0");
}

fn usesScientificNotation(value: f64) bool {
    if (value == 0) return false;
    const magnitude = @abs(value);
    return magnitude < 1e-6 or magnitude >= 1e16;
}

fn writeScientific(value: f64, out: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{e}", .{value}) catch unreachable;
    const exponent_at = std.mem.indexOfScalar(u8, text, 'e') orelse {
        try out.writeAll(text);
        return;
    };
    try out.writeAll(text[0 .. exponent_at + 1]);
    if (text[exponent_at + 1] != '-' and text[exponent_at + 1] != '+') try out.writeAll("+");
    try out.writeAll(text[exponent_at + 1 ..]);
}

// Tests.

const testing = std.testing;

fn expectParses(text: []const u8) !Document {
    var problem: Problem = .{};
    return parse(testing.allocator, text, &problem) catch |err| {
        std.debug.print("{s} refused: line {d}, column {d}: {s}\n", .{ text, problem.line, problem.column, problem.message() });
        return err;
    };
}

fn expectRefused(text: []const u8, line: u32, column: u32, message: []const u8) !void {
    var problem: Problem = .{};
    var document = parse(testing.allocator, text, &problem) catch |err| {
        try testing.expectEqual(error.InvalidJson, err);
        try testing.expectEqual(line, problem.line);
        try testing.expectEqual(column, problem.column);
        try testing.expectEqualStrings(message, problem.message());
        return;
    };
    document.deinit();
    std.debug.print("{s} was expected to be refused, but parsed\n", .{text});
    return error.TestExpectedRefusal;
}

fn expectWritten(value: Value, options: WriteOptions, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(value, options, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "every kind of scalar" {
    var document = try expectParses("[null, true, false, \"hi\", 42, -3.5, 1e2]");
    defer document.deinit();
    const items = document.root.items;
    try testing.expectEqual(.null, items[0].kind);
    try testing.expect(items[1].bool_value);
    try testing.expect(!items[2].bool_value);
    try testing.expectEqualStrings("hi", items[3].string_value);
    try testing.expect(items[4].is_integer);
    try testing.expectEqual(@as(i64, 42), items[4].int_value);
    try testing.expect(!items[5].is_integer);
    try testing.expectEqual(@as(f64, -3.5), items[5].float_value);
    try testing.expect(items[6].is_integer); // 1e2 has no fractional part
    try testing.expectEqual(@as(i64, 100), items[6].int_value);
}

test "empty containers, and nesting" {
    var document = try expectParses(" { \"a\" : [ ], \"b\" : { } } ");
    defer document.deinit();
    try testing.expectEqual(0, document.root.get("a").?.items.len);
    try testing.expectEqual(0, document.root.get("b").?.entries.len);
}

test "objects keep their keys in the order they were written" {
    var document = try expectParses("{\"z\": 1, \"a\": 2, \"m\": 3}");
    defer document.deinit();
    try testing.expectEqualStrings("z", document.root.entries[0].key);
    try testing.expectEqualStrings("a", document.root.entries[1].key);
    try testing.expectEqualStrings("m", document.root.entries[2].key);
}

test "a deeply nested list parses without recursing through Zig's call stack" {
    const opens = "[" ** max_depth;
    const closes = "]" ** max_depth;
    var document = try expectParses(opens ++ closes);
    defer document.deinit();
    var at = document.root;
    for (0..max_depth - 1) |_| at = at.items[0];
    try testing.expectEqual(0, at.items.len);
}

test "escapes, including a surrogate pair" {
    var document = try expectParses("\"a\\\"b\\\\c\\/d\\n\\t\\u0041\\ud83d\\ude00\"");
    defer document.deinit();
    try testing.expectEqualStrings("a\"b\\c/d\n\tA😀", document.root.string_value);
}

test "leading and trailing whitespace around the root value" {
    var document = try expectParses("\n\t  42  \n");
    defer document.deinit();
    try testing.expectEqual(@as(i64, 42), document.root.int_value);
}

test "a byte-order mark before the document is dropped" {
    var document = try expectParses("\xEF\xBB\xBF{}");
    defer document.deinit();
    try testing.expectEqual(.object, document.root.kind);
}

test "line and column count Unicode scalar values across lines" {
    try expectRefused("{\n  \"caf\u{E9}\": 1,\n  \"caf\u{E9}\": 2\n}", 3, 3, "the key \"café\" is already used in this object");
}

test "an empty document is refused" {
    try expectRefused("", 1, 1, "the document is empty");
    try expectRefused("   ", 1, 4, "the document is empty");
}

test "trailing commas are refused by name" {
    try expectRefused("[1, 2, ]", 1, 8, "JSON does not allow a comma before \"]\"");
    try expectRefused("{\"a\": 1, }", 1, 10, "JSON does not allow a comma before \"}\"");
}

test "single quotes are refused by name" {
    try expectRefused("'hi'", 1, 1, "JSON strings use double quotes, not single quotes");
    try expectRefused("{'a': 1}", 1, 2, "JSON strings use double quotes, not single quotes");
}

test "an unquoted key is refused with the word it found" {
    try expectRefused("{name: 1}", 1, 2, "JSON object keys need double quotes: write \"name\"");
}

test "comments are refused by name" {
    try expectRefused("// hi\n1", 1, 1, "JSON has no comments");
    try expectRefused("[1, /* hi */ 2]", 1, 5, "JSON has no comments");
}

test "NaN and Infinity are refused by name" {
    try expectRefused("NaN", 1, 1, "NaN is not a JSON number");
    try expectRefused("Infinity", 1, 1, "Infinity is not a JSON number");
    try expectRefused("-Infinity", 1, 1, "-Infinity is not a JSON number");
}

test "malformed numbers say what is wrong" {
    try expectRefused("01", 1, 1, "a number cannot have a leading zero");
    try expectRefused(".5", 1, 1, "a number needs a digit before the decimal point; write 0.5");
    try expectRefused("1.", 1, 3, "a number needs a digit after the decimal point");
    try expectRefused("1e", 1, 3, "a number needs a digit in its exponent");
    try expectRefused("+1", 1, 1, "\"+\" here does not start a value: JSON values are an object, an array, a string, a number, true, false, or null");
}

test "an unterminated string names where it started" {
    try expectRefused("[\"abc", 1, 2, "this text ends inside a string that started at line 1, column 2");
}

test "an unescaped control character is refused" {
    try expectRefused("\"a\tb\"", 1, 3, "a string cannot contain this control character unescaped; write \\n, \\t, or \\u{0009}");
}

test "a bad escape names the letter" {
    try expectRefused("\"\\x\"", 1, 2, "\"\\x\" is not a JSON escape; use \\\", \\\\, \\/, \\b, \\f, \\n, \\r, \\t, or \\u");
}

test "an unpaired surrogate is refused" {
    try expectRefused("\"\\ud83d\"", 1, 2, "a \"\\u\" escape here names half of a surrogate pair without the other half");
    try expectRefused("\"\\ude00\"", 1, 2, "a \"\\u\" escape here names half of a surrogate pair without the other half");
    try expectRefused("\"\\ud83dX\"", 1, 2, "a \"\\u\" escape here names half of a surrogate pair without the other half");
}

test "duplicate keys are refused at the second one" {
    try expectRefused("{\"a\": 1, \"a\": 2}", 1, 10, "the key \"a\" is already used in this object");
}

test "text after the root value is refused" {
    try expectRefused("1 2", 1, 3, "the document has more after this value; JSON allows only one value");
    try expectRefused("[1][2]", 1, 4, "the document has more after this value; JSON allows only one value");
}

test "nesting past the depth limit is refused" {
    const opens = "[" ** (max_depth + 1);
    try expectRefused(opens, 1, max_depth + 1, "this document is nested more than 512 levels deep");
}

test "a lone closing bracket is refused" {
    try expectRefused("]", 1, 1, "\"]\" here does not start a value: JSON values are an object, an array, a string, a number, true, false, or null");
    try expectRefused("}", 1, 1, "\"}\" here does not start a value: JSON values are an object, an array, a string, a number, true, false, or null");
    try expectRefused(",", 1, 1, "\",\" here does not start a value: JSON values are an object, an array, a string, a number, true, false, or null");
}

test "a misspelled keyword is refused with the word it found" {
    try expectRefused("True", 1, 1, "\"True\" is not a JSON value");
    try expectRefused("-Nope", 1, 1, "\"-Nope\" is not a JSON value");
}

test "writing every kind, compact" {
    try expectWritten(.initNull(), .{}, "null");
    try expectWritten(.initBool(true), .{}, "true");
    try expectWritten(.initInt(42), .{}, "42");
    try expectWritten(.initFloat(2.0), .{}, "2.0");
    try expectWritten(.initFloat(-0.0), .{}, "-0.0");
    try expectWritten(.initFloat(1.5e20), .{}, "1.5e+20");
    try expectWritten(.initString("hi \"there\"\n"), .{}, "\"hi \\\"there\\\"\\n\"");

    var items = [_]Value{ .initInt(1), .initInt(2) };
    try expectWritten(.initList(&items), .{}, "[1,2]");

    var entries = [_]Entry{ .{ .key = "b", .value = .initInt(1) }, .{ .key = "a", .value = .initInt(2) } };
    try expectWritten(.initObject(&entries), .{}, "{\"b\":1,\"a\":2}");
}

test "writing empty containers, compact and pretty" {
    try expectWritten(.initList(&.{}), .{}, "[]");
    try expectWritten(.initObject(&.{}), .{}, "{}");
    try expectWritten(.initList(&.{}), .{ .pretty = true }, "[]");
    try expectWritten(.initObject(&.{}), .{ .pretty = true }, "{}");
}

test "pretty writing indents nested containers" {
    var inner_entries = [_]Entry{ .{ .key = "name", .value = .initString("Ada") }, .{ .key = "points", .value = .initInt(120) } };
    var items = [_]Value{.initObject(&inner_entries)};
    try expectWritten(
        .initList(&items),
        .{ .pretty = true },
        "[\n  {\n    \"name\": \"Ada\",\n    \"points\": 120\n  }\n]",
    );
}

test "a non-finite number cannot be written" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.NonFiniteNumber, write(.initFloat(std.math.nan(f64)), .{}, &out.writer));
    try testing.expectError(error.NonFiniteNumber, write(.initFloat(std.math.inf(f64)), .{}, &out.writer));
}

test "writing non-ASCII text leaves it as UTF-8, unescaped" {
    try expectWritten(.initString("café 😀"), .{}, "\"café 😀\"");
}

test "round-tripping a parsed document reaches the same canonical text" {
    var document = try expectParses("{\"a\":1,\"b\":[true,false,null,\"x\"],\"c\":3.0}");
    defer document.deinit();
    try expectWritten(document.root, .{}, "{\"a\":1,\"b\":[true,false,null,\"x\"],\"c\":3.0}");
}
