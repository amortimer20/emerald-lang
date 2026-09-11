//! Runtime values and how they display.
//!
//! Only the two numeric types exist so far. Section 4.2 settles their widths as
//! language semantics rather than host details: `Int` is 64-bit signed and
//! `Float` is IEEE-754 binary64, and every backend must agree.

const std = @import("std");

const Value = @This();

pub const Kind = enum { int, float };

data: Data,

pub const Data = union(Kind) {
    int: i64,
    float: f64,
};

pub fn initInt(value: i64) Value {
    return .{ .data = .{ .int = value } };
}

pub fn initFloat(value: f64) Value {
    return .{ .data = .{ .float = value } };
}

pub fn kind(self: Value) Kind {
    return self.data;
}

/// The source spelling of this value's type, as `type_name` reports it in
/// section 4.4.
pub fn typeName(self: Value) []const u8 {
    return switch (self.data) {
        .int => "Int",
        .float => "Float",
    };
}

/// Writes the value as `print` would.
pub fn display(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.data) {
        .int => |value| try writer.print("{d}", .{value}),
        .float => |value| try displayFloat(value, writer),
    }
}

/// Section 9.4's float display, which the host does not provide.
///
/// Zig renders `2.0` as `2`, `-0.0` as `-0`, `1e16` in fixed form, and the
/// special values as `inf` and `nan`. Every one of those disagrees with the
/// specified output, so the rules are applied here rather than inherited.
pub fn displayFloat(value: f64, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.math.isNan(value)) return writer.writeAll("NaN");
    if (std.math.isPositiveInf(value)) return writer.writeAll("Infinity");
    if (std.math.isNegativeInf(value)) return writer.writeAll("-Infinity");

    if (usesScientificNotation(value)) return writeScientific(value, writer);

    // Shortest representation that parses back to the same value, with the
    // marker that identifies it as a Float restored when it rounds to a whole
    // number. This is what keeps `-0.0` distinguishable from `0`.
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try writer.writeAll(text);
    if (std.mem.indexOfScalar(u8, text, '.') == null) try writer.writeAll(".0");
}

/// Section 9.4: scientific notation for nonzero magnitudes below `1e-6` or at
/// least `1e16`. The boundary values themselves therefore display in fixed and
/// scientific form respectively, so the comparisons here are deliberately
/// asymmetric.
fn usesScientificNotation(value: f64) bool {
    if (value == 0) return false;
    const magnitude = @abs(value);
    return magnitude < 1e-6 or magnitude >= 1e16;
}

fn writeScientific(value: f64, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{e}", .{value}) catch unreachable;

    // The host omits the `+` on a positive exponent; section 9.4 requires it.
    const exponent_at = std.mem.indexOfScalar(u8, text, 'e') orelse {
        try writer.writeAll(text);
        return;
    };
    try writer.writeAll(text[0 .. exponent_at + 1]);
    if (text[exponent_at + 1] != '-' and text[exponent_at + 1] != '+') {
        try writer.writeAll("+");
    }
    try writer.writeAll(text[exponent_at + 1 ..]);
}

const testing = std.testing;

fn expectDisplay(value: Value, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try value.display(&out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "integers display without a marker" {
    try expectDisplay(.initInt(0), "0");
    try expectDisplay(.initInt(14), "14");
    try expectDisplay(.initInt(-7), "-7");
    try expectDisplay(.initInt(std.math.maxInt(i64)), "9223372036854775807");
    try expectDisplay(.initInt(std.math.minInt(i64)), "-9223372036854775808");
}

test "a whole float keeps the marker that identifies it" {
    try expectDisplay(.initFloat(2.0), "2.0");
    try expectDisplay(.initFloat(0.0), "0.0");
    try expectDisplay(.initFloat(-3.0), "-3.0");
}

test "signed zero is preserved" {
    try expectDisplay(.initFloat(-0.0), "-0.0");
}

test "a fractional float uses the shortest representation that round-trips" {
    try expectDisplay(.initFloat(0.1), "0.1");
    try expectDisplay(.initFloat(123456.789), "123456.789");
    try expectDisplay(.initFloat(1.0 / 3.0), "0.3333333333333333");
}

test "scientific notation applies outside the fixed range, boundaries included" {
    // At least 1e16 is scientific; just below it stays fixed.
    try expectDisplay(.initFloat(1e16), "1e+16");
    try expectDisplay(.initFloat(1e15), "1000000000000000.0");
    // Below 1e-6 is scientific; 1e-6 itself stays fixed.
    try expectDisplay(.initFloat(1e-6), "0.000001");
    try expectDisplay(.initFloat(1e-7), "1e-7");
}

test "special values have spelled-out names" {
    try expectDisplay(.initFloat(std.math.inf(f64)), "Infinity");
    try expectDisplay(.initFloat(-std.math.inf(f64)), "-Infinity");
    try expectDisplay(.initFloat(std.math.nan(f64)), "NaN");
}

test "type names use Emerald's spelling" {
    try testing.expectEqualStrings("Int", Value.initInt(1).typeName());
    try testing.expectEqualStrings("Float", Value.initFloat(1).typeName());
}
