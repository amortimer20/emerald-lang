//! Section 9's string operations, on UTF-8 bytes.
//!
//! Two rules from section 9 shape every one of them. A character is a grapheme
//! cluster (9.1), so indices and counts are measured in clusters and nothing
//! divides one: `"café".contains?("e")` is false when the `é` is a single
//! character, because the `e` inside it is not a character of its own.
//! Equality is canonical equivalence (9.2), so searching compares normalized
//! text: a precomposed `é` finds a decomposed one. Text already in NFC, which
//! is nearly all text, is searched as it is.

const std = @import("std");
const unicode = @import("unicode.zig");

const Allocator = std.mem.Allocator;

/// Text in NFC, borrowed when it already was and owned when it had to be
/// normalized.
const Normalized = struct {
    bytes: []const u8,
    owned: bool,

    fn of(gpa: Allocator, bytes: []const u8) Allocator.Error!Normalized {
        if (unicode.quickCheck(bytes) == .yes) return .{ .bytes = bytes, .owned = false };
        return .{ .bytes = try unicode.normalize(gpa, bytes), .owned = true };
    }

    fn deinit(self: Normalized, gpa: Allocator) void {
        if (self.owned) gpa.free(self.bytes);
    }
};

/// Which byte offsets of `bytes` fall between grapheme clusters.
const Boundaries = struct {
    set: std.DynamicBitSetUnmanaged,

    fn of(gpa: Allocator, bytes: []const u8) Allocator.Error!Boundaries {
        var set = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bytes.len + 1);
        set.set(0);
        var clusters: unicode.Graphemes = .init(bytes);
        var offset: usize = 0;
        while (clusters.next()) |cluster| {
            offset += cluster.len;
            set.set(offset);
        }
        return .{ .set = set };
    }

    fn deinit(self: *Boundaries, gpa: Allocator) void {
        self.set.deinit(gpa);
    }

    fn at(self: Boundaries, offset: usize) bool {
        return self.set.isSet(offset);
    }
};

/// A normalized haystack and needle, with the haystack's boundaries.
const Search = struct {
    haystack: Normalized,
    needle: Normalized,
    boundaries: Boundaries,

    fn init(gpa: Allocator, haystack: []const u8, needle: []const u8) Allocator.Error!Search {
        const normalized_haystack = try Normalized.of(gpa, haystack);
        errdefer normalized_haystack.deinit(gpa);
        const normalized_needle = try Normalized.of(gpa, needle);
        errdefer normalized_needle.deinit(gpa);
        return .{
            .haystack = normalized_haystack,
            .needle = normalized_needle,
            .boundaries = try Boundaries.of(gpa, normalized_haystack.bytes),
        };
    }

    fn deinit(self: *Search, gpa: Allocator) void {
        self.boundaries.deinit(gpa);
        self.needle.deinit(gpa);
        self.haystack.deinit(gpa);
    }

    /// Whether the needle occurs at `offset`, starting and ending between
    /// characters.
    fn matchesAt(self: Search, offset: usize) bool {
        const h = self.haystack.bytes;
        const n = self.needle.bytes;
        return self.boundaries.at(offset) and offset + n.len <= h.len and
            std.mem.eql(u8, h[offset..][0..n.len], n) and self.boundaries.at(offset + n.len);
    }

    /// The first match at or after `from`.
    fn next(self: Search, from: usize) ?usize {
        const h = self.haystack.bytes;
        const n = self.needle.bytes;
        var offset = from;
        while (offset + n.len <= h.len) : (offset += 1) {
            if (self.matchesAt(offset)) return offset;
        }
        return null;
    }
};

pub fn contains(gpa: Allocator, haystack: []const u8, needle: []const u8) Allocator.Error!bool {
    if (needle.len == 0) return true;
    var search = try Search.init(gpa, haystack, needle);
    defer search.deinit(gpa);
    return search.next(0) != null;
}

pub fn startsWith(gpa: Allocator, haystack: []const u8, prefix: []const u8) Allocator.Error!bool {
    if (prefix.len == 0) return true;
    var search = try Search.init(gpa, haystack, prefix);
    defer search.deinit(gpa);
    return search.matchesAt(0);
}

pub fn endsWith(gpa: Allocator, haystack: []const u8, suffix: []const u8) Allocator.Error!bool {
    if (suffix.len == 0) return true;
    var search = try Search.init(gpa, haystack, suffix);
    defer search.deinit(gpa);
    const h = search.haystack.bytes.len;
    const n = search.needle.bytes.len;
    return n <= h and search.matchesAt(h - n);
}

/// Every occurrence of `old`, left to right and without overlapping, replaced
/// by `new`. `old` is not empty. The caller owns the result.
pub fn replace(gpa: Allocator, haystack: []const u8, old: []const u8, new: []const u8) Allocator.Error![]u8 {
    var search = try Search.init(gpa, haystack, old);
    defer search.deinit(gpa);
    const h = search.haystack.bytes;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var copied: usize = 0;
    var from: usize = 0;
    while (search.next(from)) |match| {
        try result.appendSlice(gpa, h[copied..match]);
        try result.appendSlice(gpa, new);
        copied = match + search.needle.bytes.len;
        from = copied;
    }
    try result.appendSlice(gpa, h[copied..]);
    return result.toOwnedSlice(gpa);
}

/// The pieces between occurrences of `separator`, which is not empty. Each
/// piece is owned by the caller, as is the list.
pub fn split(gpa: Allocator, haystack: []const u8, separator: []const u8) Allocator.Error![][]u8 {
    var search = try Search.init(gpa, haystack, separator);
    defer search.deinit(gpa);
    const h = search.haystack.bytes;

    var pieces: std.ArrayList([]u8) = .empty;
    errdefer {
        for (pieces.items) |piece| gpa.free(piece);
        pieces.deinit(gpa);
    }
    var start: usize = 0;
    while (search.next(start)) |match| {
        try pieces.append(gpa, try gpa.dupe(u8, h[start..match]));
        start = match + search.needle.bytes.len;
    }
    try pieces.append(gpa, try gpa.dupe(u8, h[start..]));
    return pieces.toOwnedSlice(gpa);
}

/// Section 9.2's `lines()`: the text between line endings, without them. A
/// line ends at `\n`, and a `\r` before it belongs to the ending. A final line
/// ending does not start an empty last line, so `"a\nb\n"` has two lines.
pub fn lines(gpa: Allocator, bytes: []const u8) Allocator.Error![][]u8 {
    var pieces: std.ArrayList([]u8) = .empty;
    errdefer {
        for (pieces.items) |piece| gpa.free(piece);
        pieces.deinit(gpa);
    }
    var rest = bytes;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trimEnd(u8, rest[0..end], "\r");
        try pieces.append(gpa, try gpa.dupe(u8, line));
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
    }
    return pieces.toOwnedSlice(gpa);
}

/// Each character, as slices of `bytes`. The caller owns the list.
pub fn characters(gpa: Allocator, bytes: []const u8) Allocator.Error![][]const u8 {
    var pieces: std.ArrayList([]const u8) = .empty;
    var clusters: unicode.Graphemes = .init(bytes);
    while (clusters.next()) |cluster| try pieces.append(gpa, cluster);
    return pieces.toOwnedSlice(gpa);
}

/// The character at `index`, or null when there is none.
pub fn characterAt(bytes: []const u8, index: i64) ?[]const u8 {
    if (index < 0) return null;
    var clusters: unicode.Graphemes = .init(bytes);
    var position: i64 = 0;
    while (clusters.next()) |cluster| : (position += 1) {
        if (position == index) return cluster;
    }
    return null;
}

pub const Side = enum { both, start, end };

/// Whitespace removed from either end, whole characters at a time, so a
/// combining mark on a space is never left behind on its own.
pub fn trim(bytes: []const u8, side: Side) []const u8 {
    // The first and last characters that are not whitespace.
    var first: ?usize = null;
    var last_end: usize = 0;
    var clusters: unicode.Graphemes = .init(bytes);
    while (clusters.next()) |cluster| {
        if (isBlank(cluster)) continue;
        if (first == null) first = clusters.index - cluster.len;
        last_end = clusters.index;
    }
    const start = first orelse return bytes[0..0]; // all whitespace
    return switch (side) {
        .both => bytes[start..last_end],
        .start => bytes[start..],
        .end => bytes[0..last_end],
    };
}

/// Whether every character is whitespace, which an empty string trivially is.
pub fn isBlank(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const code_point, const length = unicode.decode(bytes, index);
        if (!unicode.isWhiteSpace(code_point)) return false;
        index += length;
    }
    return true;
}

/// The characters in reverse order, each kept whole. The caller owns it.
pub fn reverse(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const pieces = try characters(gpa, bytes);
    defer gpa.free(pieces);
    const result = try gpa.alloc(u8, bytes.len);
    var offset: usize = 0;
    var index = pieces.len;
    while (index > 0) {
        index -= 1;
        @memcpy(result[offset..][0..pieces[index].len], pieces[index]);
        offset += pieces[index].len;
    }
    return result;
}

/// Section 9.2's `capitalize()`: Unicode's uppercase mapping applied to the
/// first character, and the rest exactly as it was. The caller owns it.
pub fn capitalize(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var clusters: unicode.Graphemes = .init(bytes);
    const first = clusters.next() orelse return gpa.dupe(u8, bytes);
    const upper = try unicode.mapCase(gpa, first, .upper);
    defer gpa.free(upper);
    const result = try gpa.alloc(u8, upper.len + bytes.len - first.len);
    @memcpy(result[0..upper.len], upper);
    @memcpy(result[upper.len..], bytes[first.len..]);
    return result;
}

pub const SubstringError = error{ NegativeStart, NegativeCount, StartPastEnd, CountPastEnd };

/// Section 9.1's `substring(start)` and `substring(start, count)`, in
/// characters, with bounds that are errors rather than clamped. A start equal
/// to the number of characters is valid and gives an empty string.
pub fn substring(bytes: []const u8, start: i64, count: ?i64) SubstringError![]const u8 {
    if (start < 0) return error.NegativeStart;
    if (count) |wanted| if (wanted < 0) return error.NegativeCount;

    var clusters: unicode.Graphemes = .init(bytes);
    var skipped: i64 = 0;
    while (skipped < start) : (skipped += 1) {
        if (clusters.next() == null) return error.StartPastEnd;
    }
    const from = clusters.index;
    const wanted = count orelse return bytes[from..];
    var taken: i64 = 0;
    while (taken < wanted) : (taken += 1) {
        if (clusters.next() == null) return error.CountPastEnd;
    }
    return bytes[from..clusters.index];
}

pub fn ParseResult(comptime T: type) type {
    return union(enum) { value: T, malformed, out_of_range };
}

/// Section 9.4's strict parsing of a whole number: optional surrounding
/// whitespace, an optional sign, and decimal digits, all of the rest of it.
pub fn parseInt(bytes: []const u8) ParseResult(i64) {
    const trimmed = trim(bytes, .both);
    const digits = if (trimmed.len > 0 and (trimmed[0] == '+' or trimmed[0] == '-')) trimmed[1..] else trimmed;
    if (digits.len == 0) return .malformed;
    for (digits) |c| if (c < '0' or c > '9') return .malformed;
    const value = std.fmt.parseInt(i64, trimmed, 10) catch return .out_of_range;
    return .{ .value = value };
}

/// The same for a decimal number: digits, an optional fraction, and an
/// optional exponent, or the spelled-out values section 9.4 displays.
pub fn parseFloat(bytes: []const u8) ParseResult(f64) {
    const trimmed = trim(bytes, .both);
    if (std.mem.eql(u8, trimmed, "Infinity")) return .{ .value = std.math.inf(f64) };
    if (std.mem.eql(u8, trimmed, "-Infinity")) return .{ .value = -std.math.inf(f64) };
    if (std.mem.eql(u8, trimmed, "NaN")) return .{ .value = std.math.nan(f64) };

    var index: usize = 0;
    if (index < trimmed.len and (trimmed[index] == '+' or trimmed[index] == '-')) index += 1;
    const whole_start = index;
    while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) index += 1;
    if (index == whole_start) return .malformed;
    if (index < trimmed.len and trimmed[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) index += 1;
        if (index == fraction_start) return .malformed;
    }
    if (index < trimmed.len and (trimmed[index] == 'e' or trimmed[index] == 'E')) {
        index += 1;
        if (index < trimmed.len and (trimmed[index] == '+' or trimmed[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) index += 1;
        if (index == exponent_start) return .malformed;
    }
    if (index != trimmed.len) return .malformed;

    const value = std.fmt.parseFloat(f64, trimmed) catch return .malformed;
    if (std.math.isInf(value)) return .out_of_range;
    return .{ .value = value };
}

const testing = std.testing;

test "searching never divides a character" {
    // `é` here is `e` and a combining accent: one character.
    const cafe = "cafe\u{301}";
    try testing.expect(!try contains(testing.allocator, cafe, "e"));
    try testing.expect(try contains(testing.allocator, cafe, "caf"));
    try testing.expect(try contains(testing.allocator, cafe, "\u{E9}")); // precomposed finds it
    try testing.expect(try endsWith(testing.allocator, cafe, "\u{E9}"));
    try testing.expect(!try startsWith(testing.allocator, "e\u{301}", "e"));
}

test "split, replace, and lines" {
    const pieces = try split(testing.allocator, "a,,b", ",");
    defer {
        for (pieces) |piece| testing.allocator.free(piece);
        testing.allocator.free(pieces);
    }
    try testing.expectEqual(@as(usize, 3), pieces.len);
    try testing.expectEqualStrings("", pieces[1]);

    const replaced = try replace(testing.allocator, "aaa", "aa", "b");
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings("ba", replaced);

    const text_lines = try lines(testing.allocator, "one\r\ntwo\n");
    defer {
        for (text_lines) |line| testing.allocator.free(line);
        testing.allocator.free(text_lines);
    }
    try testing.expectEqual(@as(usize, 2), text_lines.len);
    try testing.expectEqualStrings("one", text_lines[0]);
}

test "trim works in whole characters" {
    try testing.expectEqualStrings("hi", trim("  hi\t\n", .both));
    try testing.expectEqualStrings("hi\t\n", trim("  hi\t\n", .start));
    try testing.expectEqualStrings("  hi", trim("  hi\t\n", .end));
    try testing.expectEqualStrings("", trim("   ", .both));
    try testing.expect(isBlank(" \u{3000}\t"));
}

test "substring counts characters and does not clamp" {
    try testing.expectEqualStrings("llo", try substring("hello", 2, null));
    try testing.expectEqualStrings("el", try substring("hello", 1, 2));
    try testing.expectEqualStrings("", try substring("hello", 5, null));
    try testing.expectError(error.StartPastEnd, substring("hello", 6, null));
    try testing.expectError(error.CountPastEnd, substring("hello", 3, 3));
    try testing.expectEqualStrings("e\u{301}", try substring("e\u{301}x", 0, 1));
}

test "parsing takes the whole string and reports what went wrong" {
    try testing.expectEqual(ParseResult(i64){ .value = 42 }, parseInt(" 42 "));
    try testing.expectEqual(ParseResult(i64){ .value = -7 }, parseInt("-7"));
    try testing.expectEqual(ParseResult(i64).malformed, parseInt("4 2"));
    try testing.expectEqual(ParseResult(i64).malformed, parseInt(""));
    try testing.expectEqual(ParseResult(i64).out_of_range, parseInt("99999999999999999999"));
    try testing.expectEqual(ParseResult(f64){ .value = 2.5 }, parseFloat("2.5"));
    try testing.expectEqual(ParseResult(f64){ .value = 3 }, parseFloat("3"));
    try testing.expectEqual(ParseResult(f64).malformed, parseFloat("3."));
    try testing.expectEqual(ParseResult(f64).out_of_range, parseFloat("1e999"));
}
