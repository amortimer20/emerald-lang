//! Emerald's Unicode: grapheme clusters, normalization, case mapping, and the
//! character classes identifiers and trimming need.
//!
//! Section 19.1 makes this Emerald's dependency rather than Zig's, because the
//! pinned standard library stops at encoding and decoding. The data comes from
//! `unicode/tables.zig`, generated from the Unicode Character Database by
//! `tools/unicode/generate.zig`, and the algorithms here are checked against
//! the conformance tests Unicode publishes with that data.
//!
//! Every string passed in is valid UTF-8. Sources are validated when loaded,
//! and every other way text enters a program validates it too.

const std = @import("std");
const tables = @import("unicode/tables.zig");

pub const version = tables.version;

// Lookup.

fn inRanges(ranges: []const tables.Range, code_point: u21) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const range = ranges[middle];
        if (code_point < range[0]) {
            high = middle;
        } else if (code_point > range[1]) {
            low = middle + 1;
        } else return true;
    }
    return false;
}

/// The value of a property held as ranges with values, or `default`.
fn valueIn(comptime Value: type, ranges: anytype, code_point: u21, default: Value) Value {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const range = ranges[middle];
        if (code_point < range[0]) {
            high = middle;
        } else if (code_point > range[1]) {
            low = middle + 1;
        } else return range[2];
    }
    return default;
}

/// The first entry whose leading field is `code_point`, from a table sorted by
/// that field.
fn entryFor(entries: anytype, code_point: u21) ?@TypeOf(entries[0]) {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = (low + high) / 2;
        if (code_point < entries[middle][0]) {
            high = middle;
        } else if (code_point > entries[middle][0]) {
            low = middle + 1;
        } else return entries[middle];
    }
    return null;
}

pub fn isIdentifierStart(code_point: u21) bool {
    return code_point == '_' or inRanges(&tables.xid_start, code_point);
}

pub fn isIdentifierContinue(code_point: u21) bool {
    return inRanges(&tables.xid_continue, code_point);
}

pub fn isWhiteSpace(code_point: u21) bool {
    return inRanges(&tables.white_space, code_point);
}

/// A word character as regular expressions' `\w` means one (UTS #18): a
/// letter or other alphabetic character, a mark, a decimal digit in any
/// script, or connector punctuation such as `_`.
pub fn isWordCharacter(code_point: u21) bool {
    return inRanges(&tables.word, code_point);
}

/// The code point Unicode's simple case folding gives, which is the code
/// point itself when folding leaves it alone. Two code points that differ only
/// in case fold to the same one.
pub fn simpleFold(code_point: u21) u21 {
    return if (entryFor(&tables.simple_fold, code_point)) |entry| entry[1] else code_point;
}

/// UnicodeData.txt's one-to-one lowercase mapping, or the code point itself.
pub fn simpleLower(code_point: u21) u21 {
    return if (entryFor(&tables.simple_lower, code_point)) |entry| entry[1] else code_point;
}

/// UnicodeData.txt's one-to-one uppercase mapping, or the code point itself.
pub fn simpleUpper(code_point: u21) u21 {
    return if (entryFor(&tables.simple_upper, code_point)) |entry| entry[1] else code_point;
}

pub fn combiningClass(code_point: u21) u8 {
    return valueIn(u8, &tables.combining_class, code_point, 0);
}

/// Decodes the code point starting at `bytes[index]`, which must begin a valid
/// sequence, and its length.
pub fn decode(bytes: []const u8, index: usize) struct { u21, u3 } {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
    const code_point = std.unicode.utf8Decode(bytes[index..][0..length]) catch unreachable;
    return .{ code_point, length };
}

fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, code_point: u21) std.mem.Allocator.Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
    try list.appendSlice(gpa, buffer[0..length]);
}

// Grapheme clusters (UAX #29).

/// Walks a string one extended grapheme cluster at a time, which is what
/// section 9.1 calls a character: `é` written as `e` and a combining accent is
/// one, and so is a family emoji built from several code points.
pub const Graphemes = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Graphemes {
        return .{ .bytes = bytes };
    }

    /// The next cluster as a slice of the string, or null at the end.
    pub fn next(self: *Graphemes) ?[]const u8 {
        if (self.index >= self.bytes.len) return null;
        const start = self.index;

        var state: Segmenter = .{};
        const first, const first_length = decode(self.bytes, self.index);
        state.begin(first);
        self.index += first_length;

        while (self.index < self.bytes.len) {
            const code_point, const length = decode(self.bytes, self.index);
            if (state.breaksBefore(code_point)) break;
            self.index += length;
        }
        return self.bytes[start..self.index];
    }
};

/// The rules of UAX #29 for extended grapheme clusters, applied one code point
/// at a time, carrying just enough context for the rules that look back
/// further than the previous code point: emoji sequences (GB11), regional
/// indicator pairs (GB12, GB13), and Indic conjuncts (GB9c).
const Segmenter = struct {
    previous: tables.GraphemeBreak = .other,
    /// Consecutive regional indicators ending with the previous code point.
    regional_indicators: usize = 0,
    /// GB11: an Extended_Pictographic followed by Extend*, then a ZWJ.
    emoji: enum { none, pictographic, joined } = .none,
    /// GB9c: a conjunct consonant followed by extenders, and whether a linker
    /// has appeared among them.
    conjunct: enum { none, consonant, linked } = .none,

    fn begin(self: *Segmenter, code_point: u21) void {
        _ = self.breaksBefore(code_point);
    }

    fn breaksBefore(self: *Segmenter, code_point: u21) bool {
        const current = valueIn(tables.GraphemeBreak, &tables.grapheme_break, code_point, .other);
        const pictographic = inRanges(&tables.extended_pictographic, code_point);
        const conjunct = valueIn(tables.ConjunctBreak, &tables.conjunct_break, code_point, .none);

        const boundary = self.rule(current, pictographic, conjunct);

        // Carry the context forward.
        self.regional_indicators = if (current == .regional_indicator) self.regional_indicators + 1 else 0;
        self.emoji = if (pictographic)
            .pictographic
        else if (self.emoji == .pictographic and current == .extend)
            .pictographic
        else if (self.emoji == .pictographic and current == .zwj)
            .joined
        else
            .none;
        self.conjunct = switch (conjunct) {
            .consonant => .consonant,
            .linker => if (self.conjunct != .none) .linked else .none,
            .extend => self.conjunct,
            .none => .none,
        };
        self.previous = current;
        return boundary;
    }

    fn rule(self: *const Segmenter, current: tables.GraphemeBreak, pictographic: bool, conjunct: tables.ConjunctBreak) bool {
        const previous = self.previous;
        // A start of text: `begin` calls with nothing before, and the answer
        // is discarded.
        if (previous == .cr and current == .lf) return false; // GB3
        if (previous == .cr or previous == .lf or previous == .control) return true; // GB4
        if (current == .cr or current == .lf or current == .control) return true; // GB5
        if (previous == .l and (current == .l or current == .v or current == .lv or current == .lvt)) return false; // GB6
        if ((previous == .lv or previous == .v) and (current == .v or current == .t)) return false; // GB7
        if ((previous == .lvt or previous == .t) and current == .t) return false; // GB8
        if (current == .extend or current == .zwj) return false; // GB9
        if (current == .spacing_mark) return false; // GB9a
        if (previous == .prepend) return false; // GB9b
        if (conjunct == .consonant and self.conjunct == .linked) return false; // GB9c
        if (pictographic and self.emoji == .joined) return false; // GB11
        if (current == .regional_indicator and self.regional_indicators % 2 == 1) return false; // GB12, GB13
        return true; // GB999
    }
};

pub fn graphemeCount(bytes: []const u8) usize {
    var count: usize = 0;
    var clusters: Graphemes = .init(bytes);
    while (clusters.next()) |_| count += 1;
    return count;
}

/// Whether `index` falls between two grapheme clusters of `bytes`, which is
/// where section 9.1 allows a string to be divided.
pub fn isGraphemeBoundary(bytes: []const u8, index: usize) bool {
    if (index == 0 or index == bytes.len) return true;
    var clusters: Graphemes = .init(bytes);
    while (clusters.next()) |cluster| {
        const end = @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr) + cluster.len;
        if (end == index) return true;
        if (end > index) return false;
    }
    return false;
}

// Normalization (UAX #15).

pub const QuickCheck = enum { yes, no, maybe };

/// Section 9.2's fast path: nearly all real text is already in NFC, and this
/// says so without allocating. `maybe` means only normalizing can tell.
pub fn quickCheck(bytes: []const u8) QuickCheck {
    var result: QuickCheck = .yes;
    var last_class: u8 = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        // ASCII is always in NFC and has combining class 0.
        if (bytes[index] < 0x80) {
            last_class = 0;
            index += 1;
            continue;
        }
        const code_point, const length = decode(bytes, index);
        index += length;
        const class = combiningClass(code_point);
        if (class != 0 and last_class > class) return .no;
        last_class = class;
        if (inRanges(&tables.nfc_quick_check_no, code_point)) return .no;
        if (inRanges(&tables.nfc_quick_check_maybe, code_point)) result = .maybe;
    }
    return result;
}

const hangul = struct {
    const s_base = 0xAC00;
    const l_base = 0x1100;
    const v_base = 0x1161;
    const t_base = 0x11A7;
    const l_count = 19;
    const v_count = 21;
    const t_count = 28;
    const n_count = v_count * t_count;
    const s_count = l_count * n_count;
};

/// The canonical composition of a string, NFC, which section 9.2 compares by.
/// The caller owns the result.
pub fn normalize(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var code_points: std.ArrayList(u21) = .empty;
    defer code_points.deinit(gpa);

    // Full canonical decomposition.
    var index: usize = 0;
    while (index < bytes.len) {
        const code_point, const length = decode(bytes, index);
        index += length;
        try decompose(gpa, &code_points, code_point);
    }

    // Canonical ordering: a stable sort of each run of nonstarters by class.
    const items = code_points.items;
    var position: usize = 1;
    while (position < items.len) : (position += 1) {
        const class = combiningClass(items[position]);
        if (class == 0) continue;
        var back = position;
        while (back > 0) {
            const before = combiningClass(items[back - 1]);
            if (before == 0 or before <= class) break;
            std.mem.swap(u21, &items[back - 1], &items[back]);
            back -= 1;
        }
    }

    // Canonical composition.
    var composed: std.ArrayList(u21) = .empty;
    defer composed.deinit(gpa);
    var starter: ?usize = null;
    var last_class: u8 = 0;
    for (items) |code_point| {
        const class = combiningClass(code_point);
        if (starter) |at| {
            const adjacent = composed.items.len - 1 == at;
            const blocked = !adjacent and (last_class == 0 or last_class >= class);
            if (!blocked) {
                if (compose(composed.items[at], code_point)) |composite| {
                    composed.items[at] = composite;
                    continue;
                }
            }
        }
        if (class == 0) {
            starter = composed.items.len;
            last_class = 0;
        } else {
            last_class = class;
        }
        try composed.append(gpa, code_point);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.ensureTotalCapacity(gpa, bytes.len);
    for (composed.items) |code_point| try append(&result, gpa, code_point);
    return result.toOwnedSlice(gpa);
}

fn decompose(gpa: std.mem.Allocator, into: *std.ArrayList(u21), code_point: u21) std.mem.Allocator.Error!void {
    if (code_point >= hangul.s_base and code_point < hangul.s_base + hangul.s_count) {
        const offset = code_point - hangul.s_base;
        try into.append(gpa, hangul.l_base + offset / hangul.n_count);
        try into.append(gpa, hangul.v_base + (offset % hangul.n_count) / hangul.t_count);
        const trailing = offset % hangul.t_count;
        if (trailing != 0) try into.append(gpa, hangul.t_base + trailing);
        return;
    }
    const entry = entryFor(&tables.decompositions, code_point) orelse return into.append(gpa, code_point);
    try into.appendSlice(gpa, tables.decomposition_data[entry[1]..][0..entry[2]]);
}

fn compose(first: u21, second: u21) ?u21 {
    // Hangul: a leading consonant and a vowel, or a syllable and a trailing
    // consonant.
    if (first >= hangul.l_base and first < hangul.l_base + hangul.l_count and
        second >= hangul.v_base and second < hangul.v_base + hangul.v_count)
    {
        return hangul.s_base + ((first - hangul.l_base) * hangul.v_count + (second - hangul.v_base)) * hangul.t_count;
    }
    if (first >= hangul.s_base and first < hangul.s_base + hangul.s_count and
        (first - hangul.s_base) % hangul.t_count == 0 and
        second > hangul.t_base and second < hangul.t_base + hangul.t_count)
    {
        return first + (second - hangul.t_base);
    }

    var low: usize = 0;
    var high: usize = tables.compositions.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const pair = tables.compositions[middle];
        const direction = if (first != pair[0]) std.math.order(first, pair[0]) else std.math.order(second, pair[1]);
        switch (direction) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return pair[2],
        }
    }
    return null;
}

/// Section 9.2's equality: canonically equivalent strings are equal. Identical
/// bytes and two strings already in NFC take the obvious fast paths.
pub fn equal(gpa: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (quickCheck(a) == .yes and quickCheck(b) == .yes) return false;
    const left = try normalize(gpa, a);
    defer gpa.free(left);
    const right = try normalize(gpa, b);
    defer gpa.free(right);
    return std.mem.eql(u8, left, right);
}

/// Section 9.2's ordering: by the code points of the normalized forms, which
/// UTF-8 byte order already is.
pub fn order(gpa: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!std.math.Order {
    if (quickCheck(a) == .yes and quickCheck(b) == .yes) return std.mem.order(u8, a, b);
    const left = try normalize(gpa, a);
    defer gpa.free(left);
    const right = try normalize(gpa, b);
    defer gpa.free(right);
    return std.mem.order(u8, left, right);
}

// Case mapping.

pub const Case = enum { lower, upper };

/// Unicode's default, locale-independent full case mapping, which section 9.2
/// asks `upper`, `lower`, and `capitalize` to use. The caller owns the result.
pub fn mapCase(gpa: std.mem.Allocator, bytes: []const u8, case: Case) std.mem.Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.ensureTotalCapacity(gpa, bytes.len);

    var index: usize = 0;
    while (index < bytes.len) {
        const code_point, const length = decode(bytes, index);
        if (case == .lower and code_point == 0x03A3 and isFinalSigma(bytes, index, length)) {
            try append(&result, gpa, 0x03C2);
        } else {
            try appendMapped(&result, gpa, code_point, case);
        }
        index += length;
    }
    return result.toOwnedSlice(gpa);
}

pub fn appendMapped(result: *std.ArrayList(u8), gpa: std.mem.Allocator, code_point: u21, case: Case) std.mem.Allocator.Error!void {
    if (entryFor(&tables.special_casing, code_point)) |entry| {
        const mapped = if (case == .lower) entry[1] else entry[2];
        for (mapped) |part| {
            if (part != 0) try append(result, gpa, part);
        }
        return;
    }
    const simple = if (case == .lower) &tables.simple_lower else &tables.simple_upper;
    const target = if (entryFor(simple, code_point)) |entry| entry[1] else code_point;
    try append(result, gpa, target);
}

/// Unicode's Final_Sigma condition: a capital sigma lowercases to `ς` when a
/// cased letter comes before it and none comes after it, looking past
/// case-ignorable characters such as apostrophes in both directions.
fn isFinalSigma(bytes: []const u8, at: usize, length: usize) bool {
    var before = at;
    var cased_before = false;
    while (before > 0) {
        var start = before - 1;
        while (start > 0 and bytes[start] & 0xC0 == 0x80) start -= 1;
        const code_point, _ = decode(bytes, start);
        before = start;
        if (inRanges(&tables.case_ignorable, code_point)) continue;
        cased_before = inRanges(&tables.cased, code_point);
        break;
    }
    if (!cased_before) return false;

    var after = at + length;
    while (after < bytes.len) {
        const code_point, const step = decode(bytes, after);
        after += step;
        if (inRanges(&tables.case_ignorable, code_point)) continue;
        return !inRanges(&tables.cased, code_point);
    }
    return true;
}

// Conformance with the data Unicode publishes.

const testing = std.testing;

fn encode(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var codes = std.mem.tokenizeScalar(u8, field, ' ');
    while (codes.next()) |code| try append(&bytes, allocator, try std.fmt.parseInt(u21, code, 16));
    return bytes.toOwnedSlice(allocator);
}

test "grapheme clusters match every case in Unicode's GraphemeBreakTest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines = std.mem.splitScalar(u8, @embedFile("unicode/test/grapheme-break.txt"), '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        // `÷ 0061 × 0308 ÷`: the clusters are what the `÷` marks separate.
        var expected: std.ArrayList([]const u8) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var cluster: std.ArrayList(u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                if (cluster.items.len > 0) try expected.append(arena, try cluster.toOwnedSlice(arena));
            } else if (!std.mem.eql(u8, token, "×")) {
                const code_point = try std.fmt.parseInt(u21, token, 16);
                try append(&cluster, arena, code_point);
                try append(&text, arena, code_point);
            }
        }

        var clusters: Graphemes = .init(text.items);
        for (expected.items) |want| {
            const got = clusters.next() orelse return error.TooFewClusters;
            testing.expectEqualSlices(u8, want, got) catch |err| {
                std.debug.print("case: {s}\n", .{line});
                return err;
            };
        }
        try testing.expect(clusters.next() == null);
        cases += 1;
    }
    try testing.expectEqual(@as(usize, 766), cases);
}

test "NFC matches Unicode's NormalizationTest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines = std.mem.splitScalar(u8, @embedFile("unicode/test/normalization.txt"), '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        var fields: [5][]u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*field| field.* = try encode(arena, parts.next().?);

        // NFC: c2 == toNFC(c1) == toNFC(c2) == toNFC(c3), and c4 == toNFC(c4) == toNFC(c5).
        for ([_]usize{ 0, 1, 2 }) |source| {
            const normalized = try normalize(arena, fields[source]);
            testing.expectEqualSlices(u8, fields[1], normalized) catch |err| {
                std.debug.print("case: {s}\n", .{line});
                return err;
            };
        }
        for ([_]usize{ 3, 4 }) |source| {
            try testing.expectEqualSlices(u8, fields[3], try normalize(arena, fields[source]));
        }
        // The quick check may say maybe, but never contradicts the answer.
        switch (quickCheck(fields[1])) {
            .yes, .maybe => {},
            .no => return error.QuickCheckRejectedNfc,
        }
        if (!std.mem.eql(u8, fields[0], fields[1])) try testing.expect(quickCheck(fields[0]) != .yes);
        cases += 1;
    }
    try testing.expect(cases > 2900);
}

test "canonically equivalent strings are equal and order the same way" {
    // `é` precomposed, and `e` followed by a combining acute accent.
    try testing.expect(try equal(testing.allocator, "caf\u{E9}", "cafe\u{301}"));
    try testing.expect(!try equal(testing.allocator, "cafe", "caf\u{E9}"));
    try testing.expectEqual(std.math.Order.eq, try order(testing.allocator, "caf\u{E9}", "cafe\u{301}"));
    try testing.expectEqual(std.math.Order.lt, try order(testing.allocator, "apple", "banana"));
}

test "a grapheme cluster is what a reader sees as one character" {
    try testing.expectEqual(@as(usize, 5), graphemeCount("he\u{301}llo"));
    // Family: man, zero-width joiner, woman, zero-width joiner, girl.
    try testing.expectEqual(@as(usize, 1), graphemeCount("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    // Two flags from four regional indicators.
    try testing.expectEqual(@as(usize, 2), graphemeCount("\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}"));
    try testing.expect(!isGraphemeBoundary("e\u{301}", 1));
    try testing.expect(isGraphemeBoundary("ab", 1));
}

test "word characters are UTS #18's, across scripts" {
    for ([_]u21{ 'a', 'Z', '0', '9', '_', 0x00E9, 0x0301, 0x4E2D, 0x0663, 0x203F, 0x200D }) |word| {
        try std.testing.expect(isWordCharacter(word));
    }
    for ([_]u21{ ' ', '-', '.', '!', 0x00A0, 0x1F600, '$' }) |other| {
        try std.testing.expect(!isWordCharacter(other));
    }
}

test "simple case folding maps both cases to one" {
    try std.testing.expectEqual(@as(u21, 'a'), simpleFold('A'));
    try std.testing.expectEqual(@as(u21, 'a'), simpleFold('a'));
    try std.testing.expectEqual(@as(u21, '1'), simpleFold('1'));
    // É and é, Greek sigma in all three forms, and the Kelvin sign.
    try std.testing.expectEqual(simpleFold(0x00C9), simpleFold(0x00E9));
    try std.testing.expectEqual(simpleFold(0x03A3), simpleFold(0x03C3));
    try std.testing.expectEqual(simpleFold(0x03C2), simpleFold(0x03C3));
    try std.testing.expectEqual(@as(u21, 'k'), simpleFold(0x212A));
    // ß has only a full folding (to "ss"), so simple folding leaves it alone,
    // while capital ẞ folds to it.
    try std.testing.expectEqual(@as(u21, 0x00DF), simpleFold(0x00DF));
    try std.testing.expectEqual(@as(u21, 0x00DF), simpleFold(0x1E9E));
}

test "case mapping is full, locale-independent, and handles final sigma" {
    const upper = try mapCase(testing.allocator, "stra\u{DF}e", .upper);
    defer testing.allocator.free(upper);
    try testing.expectEqualStrings("STRASSE", upper);

    // ΟΔΟΣ lowercases to οδος with a final sigma at the end only.
    const lower = try mapCase(testing.allocator, "\u{39F}\u{394}\u{39F}\u{3A3} \u{3A3}", .lower);
    defer testing.allocator.free(lower);
    try testing.expectEqualStrings("\u{3BF}\u{3B4}\u{3BF}\u{3C2} \u{3C3}", lower);
}

test "identifier characters follow XID, which already excludes emoji" {
    try testing.expect(isIdentifierStart('a'));
    try testing.expect(isIdentifierStart('_'));
    try testing.expect(isIdentifierStart(0x00E9)); // é
    try testing.expect(isIdentifierStart(0x5B57)); // 字
    try testing.expect(!isIdentifierStart('1'));
    try testing.expect(isIdentifierContinue('1'));
    try testing.expect(isIdentifierContinue(0x0301)); // a combining accent
    try testing.expect(!isIdentifierStart(0x1F600)); // 😀
    try testing.expect(!isIdentifierContinue(0x1F600));
    try testing.expect(isWhiteSpace(0x3000));
    try testing.expect(!isWhiteSpace('a'));
}
