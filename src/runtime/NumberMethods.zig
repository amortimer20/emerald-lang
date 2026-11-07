//! Section 9.3's `Int` and `Float` methods, as natives (`Native.zig`).

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const strings = @import("strings.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;
const widen = Native.widen;
const FloatMath = @import("FloatMath.zig");
const Range = @import("Range.zig").Range;
const toFloat = Native.toFloat;
const holdsNan = Native.holdsNan;
const integer_range_help = Native.integer_range_help;

/// Section 9.3's integer vocabulary. The checker has proved each argument is
/// an `Int`, leaving only value-dependent failures for the runtime to explain.
/// Every `Int` method these natives answer, by name.
pub const IntMethod = enum {
    abs,
    clamp,
    @"between?",
    @"zero?",
    @"positive?",
    @"negative?",
    @"even?",
    @"odd?",
    @"multiple_of?",
    digits,
    gcd,
    lcm,
    factorial,
    to_float,
    to_character,
};

pub fn intMethod(ctx: *Context, value: i64, method: IntMethod, arguments: []const Value) Error!Value {
    return switch (method) {
        .abs => if (value == std.math.minInt(i64))
            ctx.raiseFmt("the absolute value of {d} does not fit in Int", .{value}, integer_range_help)
        else
            .initInt(if (value < 0) -value else value),
        .clamp => blk: {
            const minimum = arguments[0].data.int;
            const maximum = arguments[1].data.int;
            try requireOrderedBounds(ctx, "clamp", minimum, maximum);
            break :blk .initInt(@max(minimum, @min(maximum, value)));
        },
        .@"between?" => blk: {
            const minimum = arguments[0].data.int;
            const maximum = arguments[1].data.int;
            try requireOrderedBounds(ctx, "between?", minimum, maximum);
            break :blk .initBool(value >= minimum and value <= maximum);
        },
        .@"zero?" => .initBool(value == 0),
        .@"positive?" => .initBool(value > 0),
        .@"negative?" => .initBool(value < 0),
        .@"even?" => .initBool(@mod(value, 2) == 0),
        .@"odd?" => .initBool(@mod(value, 2) != 0),
        .@"multiple_of?" => blk: {
            const divisor = arguments[0].data.int;
            if (divisor == 0) return ctx.raise(
                "`multiple_of?` cannot use zero as its divisor",
                "Pass a nonzero Int. Zero itself is a multiple of every nonzero Int.",
            );
            // Every Int is divisible by -1, including the asymmetric minimum.
            break :blk .initBool(divisor == -1 or @mod(value, divisor) == 0);
        },
        .digits => integerDigits(ctx.heap, value),
        .gcd => integerGcd(ctx, value, arguments[0].data.int),
        .lcm => integerLcm(ctx, value, arguments[0].data.int),
        .factorial => integerFactorial(ctx, value),
        .to_float => .initFloat(@floatFromInt(value)),
        .to_character => blk: {
            const problem: ?[]const u8 = if (value < 0)
                "it is negative"
            else if (value > 0x10FFFF)
                "it is past 1114111, the largest code point"
            else if (value >= 0xD800 and value <= 0xDFFF)
                "55296 to 57343 are surrogates, which only UTF-16 uses, in pairs"
            else
                null;
            if (problem) |why| return ctx.raiseFmt(
                "{d} is not a character's code point: {s}",
                .{ value, why },
                "Pass a code point such as one from `code_points()`: 0 to 1114111, leaving out 55296 to 57343.",
            );
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(@intCast(value), &buffer) catch unreachable;
            break :blk ctx.heap.copyText(buffer[0..length]);
        },
    };
}

fn requireOrderedBounds(ctx: *Context, name: []const u8, minimum: i64, maximum: i64) Error!void {
    if (minimum <= maximum) return;
    return ctx.raiseFmt(
        "`{s}` has a minimum of {d}, greater than its maximum of {d}",
        .{ name, minimum, maximum },
        "Put the lower bound first and the upper bound second.",
    );
}

fn integerLcm(ctx: *Context, left: i64, right: i64) Error!Value {
    const a = integerMagnitude(left);
    const b = integerMagnitude(right);
    if (a == 0 or b == 0) return .initInt(0);
    const divided = a / unsignedGcd(a, b);
    const result = @mulWithOverflow(divided, b);
    if (result[1] != 0 or result[0] > std.math.maxInt(i64)) return ctx.raiseFmt(
        "the least common multiple of {d} and {d} does not fit in Int",
        .{ left, right },
        integer_range_help,
    );
    return .initInt(@intCast(result[0]));
}

fn unsignedGcd(a_value: u64, b_value: u64) u64 {
    var a = a_value;
    var b = b_value;
    while (b != 0) {
        const remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

/// The unsigned magnitude avoids overflowing on the one `Int` whose positive
/// counterpart cannot be represented.
pub fn integerMagnitude(value: i64) u64 {
    if (value >= 0) return @intCast(value);
    return @as(u64, @intCast(-(value + 1))) + 1;
}

fn integerGcd(ctx: *Context, left: i64, right: i64) Error!Value {
    return checkedMagnitude(ctx, "gcd", unsignedGcd(integerMagnitude(left), integerMagnitude(right)));
}

fn checkedMagnitude(ctx: *Context, operation: []const u8, magnitude: u64) Error!Value {
    if (magnitude > std.math.maxInt(i64)) return ctx.raiseFmt(
        "the result of `{s}` does not fit in Int",
        .{operation},
        integer_range_help,
    );
    return .initInt(@intCast(magnitude));
}

fn integerFactorial(ctx: *Context, value: i64) Error!Value {
    if (value < 0) return ctx.raiseFmt(
        "a negative Int has no factorial, but this is {d}",
        .{value},
        "Call `factorial()` on 0 or a positive Int.",
    );

    var result: i64 = 1;
    var factor: i64 = 2;
    while (factor <= value) : (factor += 1) {
        const multiplied = @mulWithOverflow(result, factor);
        if (multiplied[1] != 0) return ctx.raiseFmt(
            "{d}! does not fit in Int",
            .{value},
            "The largest factorial an Int can hold is 20!.",
        );
        result = multiplied[0];
    }
    return .initInt(result);
}

fn integerDigits(heap: *Heap, value: i64) Error!Value {
    var magnitude = integerMagnitude(value);
    var reversed: [20]i64 = undefined;
    var count: usize = 0;
    if (magnitude == 0) {
        reversed[0] = 0;
        count = 1;
    } else {
        while (magnitude != 0) : (magnitude /= 10) {
            reversed[count] = @intCast(magnitude % 10);
            count += 1;
        }
    }

    const list = try heap.createList(.int, count);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);
    while (count > 0) {
        count -= 1;
        list.items.appendAssumeCapacity(.initInt(reversed[count]));
    }
    return result;
}

/// Section 9.3's floating-point vocabulary. Rounding operations that return an
/// `Int` all pass through one range and finiteness check before host conversion.
/// Every `Float` method these natives answer, by name.
pub const FloatMethod = enum {
    abs,
    clamp,
    @"between?",
    @"zero?",
    @"positive?",
    @"negative?",
    square_root,
    to_radians,
    to_degrees,
    floor,
    ceil,
    round,
    round_to,
    truncate,
    @"finite?",
    @"infinite?",
    @"nan?",
    to_int,
};

pub fn floatMethod(ctx: *Context, value: f64, method: FloatMethod, arguments: []const Value) Error!Value {
    return switch (method) {
        .abs => .initFloat(@abs(value)),
        .clamp => blk: {
            const minimum = toFloat(arguments[0]);
            const maximum = toFloat(arguments[1]);
            try requireFloatBounds(ctx, "clamp", minimum, maximum);
            break :blk .initFloat(if (value < minimum) minimum else if (value > maximum) maximum else value);
        },
        .@"between?" => blk: {
            const minimum = toFloat(arguments[0]);
            const maximum = toFloat(arguments[1]);
            try requireFloatBounds(ctx, "between?", minimum, maximum);
            break :blk .initBool(value >= minimum and value <= maximum);
        },
        .@"zero?" => .initBool(value == 0),
        .@"positive?" => .initBool(value > 0),
        .@"negative?" => .initBool(value < 0),
        .square_root => .initFloat(std.math.sqrt(value)),
        .to_radians => .initFloat(value * std.math.pi / 180.0),
        .to_degrees => .initFloat(value * 180.0 / std.math.pi),
        .floor => floatResultToInt(ctx, "floor", @floor(value)),
        .ceil => floatResultToInt(ctx, "ceil", @ceil(value)),
        .round => floatResultToInt(ctx, "round", @round(value)),
        .round_to => .initFloat(roundFloatTo(value, arguments[0].data.int)),
        .truncate, .to_int => floatResultToInt(ctx, @tagName(method), @trunc(value)),
        .@"finite?" => .initBool(std.math.isFinite(value)),
        .@"infinite?" => .initBool(std.math.isInf(value)),
        .@"nan?" => .initBool(std.math.isNan(value)),
    };
}

fn roundFloatTo(value: f64, places: i64) f64 {
    return FloatMath.roundTo(value, places);
}

fn requireFloatBounds(ctx: *Context, name: []const u8, minimum: f64, maximum: f64) Error!void {
    if (std.math.isNan(minimum) or std.math.isNan(maximum)) return ctx.raiseFmt(
        "`{s}` cannot use NaN as a bound",
        .{name},
        "Use ordered Float bounds. NaN is not less than, equal to, or greater than any value.",
    );
    if (minimum <= maximum) return;

    var minimum_text: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer minimum_text.deinit();
    try Value.initFloat(minimum).display(&minimum_text.writer);
    var maximum_text: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer maximum_text.deinit();
    try Value.initFloat(maximum).display(&maximum_text.writer);
    return ctx.raiseFmt(
        "`{s}` has a minimum of {s}, greater than its maximum of {s}",
        .{ name, minimum_text.written(), maximum_text.written() },
        "Put the lower bound first and the upper bound second.",
    );
}

/// Converts an already-rounded Float only after proving Zig's `@intFromFloat`
/// is defined. The upper comparison is inclusive because 2^63 is exactly
/// representable as a Float but is one beyond the greatest `Int`.
fn floatResultToInt(ctx: *Context, operation: []const u8, value: f64) Error!Value {
    if (!std.math.isFinite(value)) return ctx.raiseFmt(
        "`{s}` cannot produce an Int from a non-finite Float",
        .{operation},
        "Check `finite?()` first. NaN and infinity cannot be represented by Int.",
    );
    if (value >= 9223372036854775808.0 or value < -9223372036854775808.0) return ctx.raiseFmt(
        "the result of `{s}` is outside the range of Int",
        .{operation},
        integer_range_help,
    );
    return .initInt(@intFromFloat(value));
}
