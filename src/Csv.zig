//! Section 15.11's CSV parser and writer, independent of Emerald values.
//!
//! CSV is a table of text, so its parser makes no attempt to guess numbers,
//! dates, or headers. It preserves each row's physical starting line for the
//! later `CsvError` and typed-decoding layers. Quoting follows RFC 4180 where
//! it matters to ordinary spreadsheet files: `""` writes one quote, a quoted
//! field may contain a comma or a line break, and both Unix and Windows line
//! endings are accepted. A final line ending ends its row rather than adding
//! a spurious empty row.

const std = @import("std");
const unicode = @import("unicode.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = Allocator.Error || error{InvalidCsv};
pub const WriteError = std.Io.Writer.Error || error{InvalidSeparator};

/// A parsed field row. `line` is one-based and is the physical line on which
/// the row starts, even when an earlier quoted field holds a line break.
pub const Row = struct {
    line: u32,
    fields: []const []const u8,
};

/// The parser owns all decoded fields through one arena, so rows stay valid
/// until `deinit` and callers need not retain the input text.
pub const Document = struct {
    arena_state: std.heap.ArenaAllocator,
    rows: []const Row = &.{},

    pub fn deinit(self: *Document) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

/// Why text was refused. `line` is absent only when no physical line exists,
/// such as a bad separator. The interpreter later turns this into `CsvError`.
pub const Problem = struct {
    line: ?u32 = null,
    buffer: [400]u8 = undefined,
    length: usize = 0,

    pub fn message(self: *const Problem) []const u8 {
        return self.buffer[0..self.length];
    }

    fn fail(self: *Problem, line: ?u32, comptime format: []const u8, arguments: anytype) error{InvalidCsv} {
        self.line = line;
        const written = std.fmt.bufPrint(&self.buffer, format, arguments) catch {
            self.length = self.buffer.len;
            return error.InvalidCsv;
        };
        self.length = written.len;
        return error.InvalidCsv;
    }
};

/// Parses every CSV row, including a header if one is present. `separator`
/// must be exactly one Emerald character; it may be a multibyte character.
pub fn parse(gpa: Allocator, input: []const u8, separator: []const u8, problem: *Problem) ParseError!Document {
    problem.* = .{};
    if (unicode.graphemeCount(separator) != 1) {
        return problem.fail(null, "a separator must be one character, not \"{s}\"", .{separator});
    }

    var document: Document = .{ .arena_state = .init(gpa) };
    errdefer document.deinit();
    const allocator = document.arena_state.allocator();
    var rows: std.ArrayList(Row) = .empty;

    var index: usize = if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) 3 else 0;
    var line: u32 = 1;
    while (index < input.len) {
        const row_line = line;
        var fields: std.ArrayList([]const u8) = .empty;

        while (true) {
            var field: std.ArrayList(u8) = .empty;
            if (index == input.len) {
                // A separator at the true end of a row names one final empty
                // field, not an attempt to read beyond the input.
            } else if (input[index] == '"') {
                const quote_line = line;
                index += 1;
                while (true) {
                    if (index == input.len) {
                        return problem.fail(quote_line, "a quoted field that starts here never closes", .{});
                    }
                    if (input[index] == '"') {
                        if (index + 1 < input.len and input[index + 1] == '"') {
                            try field.append(allocator, '"');
                            index += 2;
                            continue;
                        }
                        index += 1;
                        break;
                    }
                    if (input[index] == '\r' and index + 1 < input.len and input[index + 1] == '\n') {
                        try field.appendSlice(allocator, "\r\n");
                        index += 2;
                        line += 1;
                        continue;
                    }
                    if (input[index] == '\n') {
                        try field.append(allocator, '\n');
                        index += 1;
                        line += 1;
                        continue;
                    }
                    try field.append(allocator, input[index]);
                    index += 1;
                }
                if (index < input.len and !atSeparator(input, index, separator) and !atLineEnd(input, index)) {
                    const end = nextScalarEnd(input, index);
                    return problem.fail(line, "a quoted field must end at a separator or the end of the line, not \"{s}\"", .{input[index..end]});
                }
            } else {
                while (index < input.len and !atSeparator(input, index, separator) and !atLineEnd(input, index)) {
                    try field.append(allocator, input[index]);
                    index += 1;
                }
            }
            try fields.append(allocator, try field.toOwnedSlice(allocator));

            if (index == input.len) break;
            if (atSeparator(input, index, separator)) {
                index += separator.len;
                continue;
            }
            consumeLineEnd(input, &index, &line);
            break;
        }
        try rows.append(allocator, .{ .line = row_line, .fields = try fields.toOwnedSlice(allocator) });
    }
    document.rows = try rows.toOwnedSlice(allocator);
    return document;
}

/// Writes rows with `\n` line endings. A field is quoted only when leaving it
/// bare would change how this parser reads it: it holds the separator, a
/// quote, a line break, or starts or ends with an ordinary space.
pub fn write(rows: []const []const []const u8, separator: []const u8, out: *std.Io.Writer) WriteError!void {
    if (unicode.graphemeCount(separator) != 1) return error.InvalidSeparator;
    for (rows, 0..) |row, row_index| {
        if (row_index != 0) try out.writeByte('\n');
        for (row, 0..) |field, field_index| {
            if (field_index != 0) try out.writeAll(separator);
            if (needsQuotes(field, separator)) {
                try out.writeByte('"');
                for (field) |byte| {
                    if (byte == '"') try out.writeByte('"');
                    try out.writeByte(byte);
                }
                try out.writeByte('"');
            } else {
                try out.writeAll(field);
            }
        }
    }
}

fn atSeparator(input: []const u8, index: usize, separator: []const u8) bool {
    return index + separator.len <= input.len and std.mem.eql(u8, input[index .. index + separator.len], separator);
}

fn atLineEnd(input: []const u8, index: usize) bool {
    return input[index] == '\n' or (input[index] == '\r' and index + 1 < input.len and input[index + 1] == '\n');
}

fn consumeLineEnd(input: []const u8, index: *usize, line: *u32) void {
    if (input[index.*] == '\r') index.* += 1;
    index.* += 1; // the `\n`, either on its own or after `\r`
    line.* += 1;
}

/// Keep a parse diagnostic valid UTF-8 even when the unexpected text is not
/// ASCII. CSV is text, so showing its next Unicode scalar is more useful than
/// exposing the leading byte as an implementation detail.
fn nextScalarEnd(input: []const u8, index: usize) usize {
    const byte_count = std.unicode.utf8ByteSequenceLength(input[index]) catch return index + 1;
    return @min(input.len, index + byte_count);
}

fn needsQuotes(field: []const u8, separator: []const u8) bool {
    if (field.len == 0) return false;
    if (field[0] == ' ' or field[field.len - 1] == ' ') return true;
    return std.mem.indexOf(u8, field, separator) != null or
        std.mem.indexOfScalar(u8, field, '"') != null or
        std.mem.indexOfScalar(u8, field, '\n') != null or
        std.mem.indexOfScalar(u8, field, '\r') != null;
}

// Tests.

const testing = std.testing;

fn expectParses(text: []const u8, separator: []const u8) !Document {
    var problem: Problem = .{};
    return parse(testing.allocator, text, separator, &problem) catch |err| {
        std.debug.print("{s} refused: {s}\n", .{ text, problem.message() });
        return err;
    };
}

fn expectRefused(text: []const u8, separator: []const u8, line: ?u32, message: []const u8) !void {
    var problem: Problem = .{};
    var document = parse(testing.allocator, text, separator, &problem) catch |err| {
        try testing.expectEqual(error.InvalidCsv, err);
        try testing.expectEqual(line, problem.line);
        try testing.expectEqualStrings(message, problem.message());
        return;
    };
    document.deinit();
    return error.TestExpectedRefusal;
}

fn expectWritten(rows: []const []const []const u8, separator: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(rows, separator, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "CSV parses ordinary and uneven rows" {
    var document = try expectParses("name,points\nAda,120\nsolo", ",");
    defer document.deinit();
    try testing.expectEqual(@as(usize, 3), document.rows.len);
    try testing.expectEqual(@as(u32, 1), document.rows[0].line);
    try testing.expectEqualStrings("name", document.rows[0].fields[0]);
    try testing.expectEqualStrings("120", document.rows[1].fields[1]);
    try testing.expectEqual(@as(usize, 1), document.rows[2].fields.len);
}

test "CSV parses quotes separators escapes and line breaks" {
    var document = try expectParses("name,note\n\"Hopper, Grace\",\"said \"\"hi\"\"\"\nAda,\"one\ntwo\"", ",");
    defer document.deinit();
    try testing.expectEqual(@as(usize, 3), document.rows.len);
    try testing.expectEqualStrings("Hopper, Grace", document.rows[1].fields[0]);
    try testing.expectEqualStrings("said \"hi\"", document.rows[1].fields[1]);
    try testing.expectEqual(@as(u32, 3), document.rows[2].line);
    try testing.expectEqualStrings("one\ntwo", document.rows[2].fields[1]);
}

test "CSV accepts a BOM Windows line endings and no final empty row" {
    var document = try expectParses("\xEF\xBB\xBFa;b\r\n1;2\r\n", ";");
    defer document.deinit();
    try testing.expectEqual(@as(usize, 2), document.rows.len);
    try testing.expectEqual(@as(u32, 2), document.rows[1].line);
    try testing.expectEqualStrings("b", document.rows[0].fields[1]);
}

test "CSV accepts a one-grapheme Unicode separator" {
    var document = try expectParses("lefte\u{301}right\n1e\u{301}2", "e\u{301}");
    defer document.deinit();
    try testing.expectEqualStrings("right", document.rows[0].fields[1]);
    try testing.expectEqualStrings("2", document.rows[1].fields[1]);
}

test "CSV reports quote and separator errors" {
    try expectRefused("name\n\"Ada", ",", 2, "a quoted field that starts here never closes");
    try expectRefused("name\n\"Ada\"x", ",", 2, "a quoted field must end at a separator or the end of the line, not \"x\"");
    try expectRefused("name\n\"Ada\"é", ",", 2, "a quoted field must end at a separator or the end of the line, not \"é\"");
    try expectRefused("name", ";;", null, "a separator must be one character, not \";;\"");
}

test "CSV writes minimally quoted Unix rows" {
    try expectWritten(&.{
        &.{ "name", "note" },
        &.{ "Ada", "plain" },
        &.{ "Hopper, Grace", "said \"hi\"" },
        &.{ " spaced ", "one\ntwo" },
    }, ",", "name,note\nAda,plain\n\"Hopper, Grace\",\"said \"\"hi\"\"\"\n\" spaced \",\"one\ntwo\"");
}

test "CSV writer rejects a separator longer than one character" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.InvalidSeparator, write(&.{}, ";;", &out.writer));
}

test "CSV writer round trips quoted fields and custom separators" {
    const rows = &.{ &.{ "a", "b;c", "line\ntwo" }, &.{ "", "x", "y" } };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(rows, ";", &out.writer);
    var document = try expectParses(out.written(), ";");
    defer document.deinit();
    try testing.expectEqual(@as(usize, 2), document.rows.len);
    try testing.expectEqualStrings("b;c", document.rows[0].fields[1]);
    try testing.expectEqualStrings("line\ntwo", document.rows[0].fields[2]);
    try testing.expectEqualStrings("", document.rows[1].fields[0]);
}
