//! Checks Emerald's normalization against the whole of Unicode's
//! NormalizationTest.txt, including Part 1, the character-by-character test
//! the committed subset leaves out, and its rule that every code point not
//! listed there is its own NFC.
//!
//!     zig build unicode-conformance -Doptimize=ReleaseSafe -- .unicode/17.0.0

const std = @import("std");
const unicode = @import("emerald").unicode;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: unicode-conformance <database directory>\n", .{});
        std.process.exit(64);
    }
    const path = try std.fs.path.join(arena, &.{ args[1], "NormalizationTest.txt" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));

    var listed: std.AutoHashMapUnmanaged(u21, void) = .empty;
    var in_part_one = false;
    var cases: usize = 0;
    var failures: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |at| raw[0..at] else raw;
        if (line.len == 0) continue;
        if (line[0] == '@') {
            in_part_one = std.mem.startsWith(u8, line, "@Part1");
            continue;
        }

        var fields: [5][]u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*field| field.* = try encode(arena, parts.next().?);
        if (in_part_one) try listed.put(arena, (try std.unicode.utf8Decode(fields[0][0..try std.unicode.utf8ByteSequenceLength(fields[0][0])])), {});

        for ([_]usize{ 0, 1, 2 }) |source| {
            if (!std.mem.eql(u8, fields[1], try unicode.normalize(arena, fields[source]))) failures += 1;
        }
        for ([_]usize{ 3, 4 }) |source| {
            if (!std.mem.eql(u8, fields[3], try unicode.normalize(arena, fields[source]))) failures += 1;
        }
        cases += 1;
    }

    // Every code point Part 1 does not list normalizes to itself.
    var unlisted: usize = 0;
    var code_point: u21 = 0;
    while (code_point <= 0x10FFFF) : (code_point += 1) {
        if (code_point >= 0xD800 and code_point <= 0xDFFF) continue;
        if (listed.contains(code_point)) continue;
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
        const normalized = try unicode.normalize(init.gpa, buffer[0..length]);
        defer init.gpa.free(normalized);
        if (!std.mem.eql(u8, buffer[0..length], normalized)) failures += 1;
        unlisted += 1;
    }

    std.debug.print("Unicode {s}: {d} cases and {d} unlisted code points, {d} failures\n", .{
        unicode.version, cases, unlisted, failures,
    });
    if (failures != 0) std.process.exit(1);
}

fn encode(arena: std.mem.Allocator, field: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var codes = std.mem.tokenizeScalar(u8, field, ' ');
    while (codes.next()) |code| {
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(try std.fmt.parseInt(u21, code, 16), &buffer);
        try bytes.appendSlice(arena, buffer[0..length]);
    }
    return bytes.toOwnedSlice(arena);
}
