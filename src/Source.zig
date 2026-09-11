//! An immutable record of one loaded Emerald source file.
//!
//! Every token, syntax node, diagnostic, and future stack frame refers back into
//! a `Source` through a `Span` of byte offsets, so there is exactly one place
//! that knows how bytes map to the line and column a reader sees.
//!
//! Offsets are relative to `text`, which has any UTF-8 byte-order mark removed.

const std = @import("std");

const Source = @This();

/// A half-open range of byte offsets into `Source.text`.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};

/// A one-based position for display. `column` counts Unicode scalar values, not
/// bytes, matching the column encoding the CLI contract promises in section 18.1.
pub const Location = struct {
    line: u32,
    column: u32,
};

path: []const u8,
text: []const u8,
/// Byte offset of the first character of each line. Always has at least one entry.
line_starts: []const u32,

pub const max_bytes = 64 * 1024 * 1024;

pub const LoadError = std.Io.Dir.ReadFileAllocError || std.mem.Allocator.Error;

/// Reads `path` and retains its contents. The caller owns the result.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Source {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
    defer gpa.free(raw);
    return init(gpa, path, raw);
}

/// Retains a copy of `bytes` as the contents of `path`.
pub fn init(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) std.mem.Allocator.Error!Source {
    const body = stripByteOrderMark(bytes);

    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);

    const owned_text = try gpa.dupe(u8, body);
    errdefer gpa.free(owned_text);

    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    for (owned_text, 0..) |byte, index| {
        if (byte == '\n') try starts.append(gpa, @intCast(index + 1));
    }

    return .{
        .path = owned_path,
        .text = owned_text,
        .line_starts = try starts.toOwnedSlice(gpa),
    };
}

pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    gpa.free(self.text);
    gpa.free(self.line_starts);
    self.* = undefined;
}

pub fn lineCount(self: Source) u32 {
    return @intCast(self.line_starts.len);
}

/// Converts a byte offset into the one-based line and scalar column a reader sees.
/// An offset at or past the end of the text reports the final position.
pub fn location(self: Source, offset: u32) Location {
    const clamped = @min(offset, self.text.len);
    const line_index = self.lineIndexAt(clamped);
    const line_start = self.line_starts[line_index];
    return .{
        .line = line_index + 1,
        .column = scalarCount(self.text[line_start..clamped]) + 1,
    };
}

/// Returns the text of a one-based line, excluding its line terminator.
pub fn lineText(self: Source, line: u32) []const u8 {
    const line_index = line - 1;
    const start = self.line_starts[line_index];
    var end: usize = if (line_index + 1 < self.line_starts.len)
        self.line_starts[line_index + 1] - 1 // the '\n' itself
    else
        self.text.len;
    if (end > start and self.text[end - 1] == '\r') end -= 1;
    return self.text[start..end];
}

fn lineIndexAt(self: Source, offset: usize) u32 {
    var low: usize = 0;
    var high: usize = self.line_starts.len;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (self.line_starts[middle] <= offset) low = middle else high = middle;
    }
    return @intCast(low);
}

fn stripByteOrderMark(bytes: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
}

/// Counts Unicode scalar values by counting bytes that begin a sequence.
/// Continuation bytes match 0b10xxxxxx and are skipped.
fn scalarCount(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// Returns the span of the first byte sequence that is not valid UTF-8, or null
/// when the whole text is valid. Section 3.1 requires malformed input to be
/// reported at the offending byte span rather than at the end of the file.
pub fn findInvalidUtf8(text: []const u8) ?Span {
    var index: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            return .{ .start = @intCast(index), .end = @intCast(index + 1) };
        };
        if (index + width > text.len) {
            return .{ .start = @intCast(index), .end = @intCast(text.len) };
        }
        _ = std.unicode.utf8Decode(text[index .. index + width]) catch {
            return .{ .start = @intCast(index), .end = @intCast(index + width) };
        };
        index += width;
    }
    return null;
}

const testing = std.testing;

test "locations are one-based and count scalars, not bytes" {
    var source = try Source.init(testing.allocator, "main.em", "var name = 1\nprint(name)\n");
    defer source.deinit(testing.allocator);

    try testing.expectEqual(Location{ .line = 1, .column = 1 }, source.location(0));
    try testing.expectEqual(Location{ .line = 1, .column = 5 }, source.location(4));
    try testing.expectEqual(Location{ .line = 2, .column = 1 }, source.location(13));
    try testing.expectEqualStrings("var name = 1", source.lineText(1));
    try testing.expectEqualStrings("print(name)", source.lineText(2));
}

test "multi-byte scalars advance the column by one each" {
    // "héllo" — the accented letter occupies two bytes.
    var source = try Source.init(testing.allocator, "main.em", "var x = \"héllo\"");
    defer source.deinit(testing.allocator);

    const offset: u32 = @intCast(std.mem.indexOf(u8, source.text, "llo").?);
    try testing.expectEqual(Location{ .line = 1, .column = 12 }, source.location(offset));
}

test "a byte-order mark is removed and does not shift offsets" {
    var source = try Source.init(testing.allocator, "main.em", "\xEF\xBB\xBFvar x = 1");
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("var x = 1", source.text);
    try testing.expectEqual(Location{ .line = 1, .column = 1 }, source.location(0));
}

test "carriage returns are excluded from line text" {
    var source = try Source.init(testing.allocator, "main.em", "one\r\ntwo\r\n");
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("one", source.lineText(1));
    try testing.expectEqualStrings("two", source.lineText(2));
    try testing.expectEqual(@as(u32, 3), source.lineCount());
}

test "a file without a trailing newline still reports its last line" {
    var source = try Source.init(testing.allocator, "main.em", "one\ntwo");
    defer source.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), source.lineCount());
    try testing.expectEqualStrings("two", source.lineText(2));
}

test "valid UTF-8 reports no invalid span" {
    try testing.expectEqual(@as(?Span, null), findInvalidUtf8("plain ascii"));
    try testing.expectEqual(@as(?Span, null), findInvalidUtf8("héllo 👋"));
}

test "invalid UTF-8 is reported at the offending byte span" {
    // 0xFF never begins a valid UTF-8 sequence.
    try testing.expectEqual(Span{ .start = 3, .end = 4 }, findInvalidUtf8("abc\xFFdef").?);
    // A truncated three-byte sequence at end of input.
    try testing.expectEqual(Span{ .start = 3, .end = 5 }, findInvalidUtf8("abc\xE2\x82").?);
    // A well-formed length with a bad continuation byte.
    try testing.expectEqual(Span{ .start = 0, .end = 2 }, findInvalidUtf8("\xC3\x28").?);
}
