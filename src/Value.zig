//! Runtime values and how they display.
//!
//! `Nothing`, `Bool`, `Int`, and `Float` exist so far. Section 4.2 settles the numeric
//! widths as language semantics rather than host details: `Int` is 64-bit signed
//! and `Float` is IEEE-754 binary64, and every backend must agree.

const std = @import("std");

const Value = @This();

pub const Kind = enum { nothing, bool, int, float };

data: Data,

pub const Data = union(Kind) {
    /// Section 4.2's absence-only type. Its single value is written `nothing`.
    nothing: void,
    bool: bool,
    int: i64,
    float: f64,
};

pub const nothing: Value = .{ .data = .nothing };

pub fn initBool(value: bool) Value {
    return .{ .data = .{ .bool = value } };
}

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
        .nothing => "Nothing",
        .bool => "Bool",
        .int => "Int",
        .float => "Float",
    };
}

/// Whether two values are numbers, which is what arithmetic and ordering need.
pub fn isNumber(self: Value) bool {
    return switch (self.data) {
        .nothing, .bool => false,
        .int, .float => true,
    };
}

/// Writes the value as `print` would.
pub fn display(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.data) {
        .nothing => try writer.writeAll("nothing"),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .int => |value| try writer.print("{d}", .{value}),
        .float => |value| try displayFloat(value, writer),
    }
}

/// Emerald's `==`. Numbers compare by mathematical value, as `order` does, so
/// a NaN equals nothing, itself included. Values of different kinds are never
/// equal; the checker rejects comparing them, so that answer is a safety net.
pub fn equals(left: Value, right: Value) bool {
    return switch (left.data) {
        .nothing => right.data == .nothing,
        .bool => |a| switch (right.data) {
            .bool => |b| a == b,
            else => false,
        },
        .int, .float => order(left, right) == .eq,
    };
}

/// Orders two numbers, or reports that they are unordered because one is NaN.
///
/// Section 4.4 requires a mixed comparison to compare mathematical values
/// "without first rounding the integer into `Float`". That rules out the obvious
/// implementation. Widening an `Int` to `Float` loses precision above 2^53, so
/// converting first would make `9007199254740993 == 9007199254740992.0` true,
/// which is exactly the accidental equality the rule forbids.
pub fn order(left: Value, right: Value) ?std.math.Order {
    return switch (left.data) {
        .int => |a| switch (right.data) {
            .int => |b| std.math.order(a, b),
            .float => |b| orderIntFloat(a, b),
            .nothing, .bool => null,
        },
        .float => |a| switch (right.data) {
            .int => |b| if (orderIntFloat(b, a)) |result| result.invert() else null,
            .float => |b| if (std.math.isNan(a) or std.math.isNan(b))
                null
            else
                std.math.order(a, b),
            .nothing, .bool => null,
        },
        .nothing, .bool => null,
    };
}

/// Compares an `Int` against a `Float` exactly, by splitting the float rather
/// than widening the integer.
fn orderIntFloat(a: i64, b: f64) ?std.math.Order {
    if (std.math.isNan(b)) return null;
    if (std.math.isPositiveInf(b)) return .lt;
    if (std.math.isNegativeInf(b)) return .gt;

    // Outside the Int range the float wins on magnitude alone. The bounds are
    // exact powers of two, so these comparisons are themselves exact.
    const whole = @floor(b);
    if (whole >= 9223372036854775808.0) return .lt; // 2^63, one past max Int
    if (whole < -9223372036854775808.0) return .gt; // -2^63 is min Int itself

    const truncated: i64 = @intFromFloat(whole);
    if (a != truncated) return std.math.order(a, truncated);

    // Whole parts agree, so any fraction makes the float the larger value.
    return if (b > whole) .lt else .eq;
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

test "booleans display as the words they are written with" {
    try expectDisplay(.initBool(true), "true");
    try expectDisplay(.initBool(false), "false");
    try testing.expectEqualStrings("Bool", Value.initBool(true).typeName());
}

test "integers order against each other exactly" {
    try testing.expectEqual(std.math.Order.lt, Value.order(.initInt(1), .initInt(2)).?);
    try testing.expectEqual(std.math.Order.eq, Value.order(.initInt(2), .initInt(2)).?);
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(3), .initInt(2)).?);
}

test "a mixed comparison does not widen the integer first" {
    // 9007199254740993 is 2^53 + 1, the smallest integer f64 cannot represent.
    // Widening it would round to 9007199254740992.0 and make these equal, which
    // is the accidental equality section 4.4 forbids.
    const big: i64 = 9007199254740993;
    const rounded: f64 = 9007199254740992.0;
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(big), .initFloat(rounded)).?);
    try testing.expectEqual(std.math.Order.lt, Value.order(.initFloat(rounded), .initInt(big)).?);
}

test "a mixed comparison respects the fractional part" {
    try testing.expectEqual(std.math.Order.lt, Value.order(.initInt(2), .initFloat(2.5)).?);
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(3), .initFloat(2.5)).?);
    try testing.expectEqual(std.math.Order.eq, Value.order(.initInt(2), .initFloat(2.0)).?);
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(-2), .initFloat(-2.5)).?);
    try testing.expectEqual(std.math.Order.lt, Value.order(.initInt(-3), .initFloat(-2.5)).?);
}

test "a mixed comparison handles values beyond the Int range" {
    try testing.expectEqual(std.math.Order.lt, Value.order(.initInt(std.math.maxInt(i64)), .initFloat(1e30)).?);
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(std.math.minInt(i64)), .initFloat(-1e30)).?);
    try testing.expectEqual(std.math.Order.lt, Value.order(.initInt(0), .initFloat(std.math.inf(f64))).?);
    try testing.expectEqual(std.math.Order.gt, Value.order(.initInt(0), .initFloat(-std.math.inf(f64))).?);
}

test "the minimum Int compares exactly against its own float value" {
    const min: i64 = std.math.minInt(i64);
    try testing.expectEqual(std.math.Order.eq, Value.order(.initInt(min), .initFloat(-9223372036854775808.0)).?);
}

test "NaN is unordered against everything, including itself" {
    const nan = Value.initFloat(std.math.nan(f64));
    try testing.expect(Value.order(nan, .initFloat(1.0)) == null);
    try testing.expect(Value.order(.initFloat(1.0), nan) == null);
    try testing.expect(Value.order(nan, .initInt(1)) == null);
    try testing.expect(Value.order(.initInt(1), nan) == null);
    try testing.expect(Value.order(nan, nan) == null);
}

test "a Bool is not ordered against a number" {
    try testing.expect(Value.order(.initBool(true), .initInt(1)) == null);
    try testing.expect(Value.order(.initInt(1), .initBool(true)) == null);
}
