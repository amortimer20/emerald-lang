//! The operations a program spells with syntax rather than a call: arithmetic,
//! negation, `not`, comparison, indexing and slicing, a dictionary entry, and a
//! name read before it is assigned (docs/compiler-design-plan.md, slice 1c).
//!
//! Each engine does the common case itself, such as an addition that does
//! not overflow or an index inside its list, and calls these for the rest, so
//! a beginner reads the same message from either engine. The interpreter
//! calls them through `runNativeCold`. The checker has already ruled out every
//! failure the types decide; what is left here depends on values.

const std = @import("std");
const Value = @import("Value.zig");
const Range = @import("Range.zig").Range;
const Native = @import("Native.zig");
const FloatMath = @import("FloatMath.zig");

const Context = Native.Context;
const Error = Native.Error;
const integer_range_help = Native.integer_range_help;

/// Section 5.3's arithmetic operators. The front end's syntax tree uses this
/// type too (`Ast.BinaryOperator`).
pub const Arithmetic = enum {
    add,
    subtract,
    multiply,
    /// `/`, which always produces a `Float`.
    divide,
    /// `//`, which rounds toward negative infinity.
    floor_divide,
    /// `%`, paired with floor division by the law `a == (a // b) * b + (a % b)`.
    remainder,
    /// `**`, which gives an `Int` for two `Int`s and associates right to left.
    power,

    pub fn lexeme(self: Arithmetic) []const u8 {
        return switch (self) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .floor_divide => "//",
            .remainder => "%",
            .power => "**",
        };
    }

    /// How the operator reads in a message, in the user's vocabulary, as in
    /// "addition of 1 and 2".
    pub fn describe(self: Arithmetic) []const u8 {
        return switch (self) {
            .add => "addition",
            .subtract => "subtraction",
            .multiply => "multiplication",
            .divide => "division",
            .floor_divide => "floor division",
            .remainder => "remainder",
            .power => "exponentiation",
        };
    }
};

/// `left op right` for two `Int`s; `divide` gives a `Float`, so it is not one
/// of these. Overflow and division by zero raise.
pub fn intArithmetic(ctx: *Context, operator: Arithmetic, left: i64, right: i64) Error!i64 {
    switch (operator) {
        .add, .subtract, .multiply => {
            const result = switch (operator) {
                .add => @addWithOverflow(left, right),
                .subtract => @subWithOverflow(left, right),
                .multiply => @mulWithOverflow(left, right),
                else => unreachable,
            };
            if (result[1] != 0) return overflow(ctx, operator, left, right);
            return result[0];
        },
        .floor_divide => {
            if (right == 0) return divisionByZero(ctx, operator);
            // The only overflowing quotient: the minimum Int divided by -1 has
            // no positive counterpart in an asymmetric range.
            if (left == std.math.minInt(i64) and right == -1) return overflow(ctx, operator, left, right);
            return @divFloor(left, right);
        },
        .remainder => {
            if (right == 0) return divisionByZero(ctx, operator);
            // Every value is exactly divisible by -1, so the remainder is zero.
            // Stating it avoids relying on host behavior at the range edge.
            if (right == -1) return 0;
            return @mod(left, right);
        },
        .power => return intPower(ctx, left, right),
        .divide => unreachable, // a Float operation whatever the operands
    }
}

/// Section 5.3: two `Int`s give an `Int`, so `side ** 2` stays whole. An `Int`
/// has no fraction to hold `2 ** -1`, so a negative exponent raises and points
/// at the `Float` spelling.
///
/// Squaring by repeated halving takes as many steps as the exponent has bits,
/// so `1 ** 1_000_000_000` is instant. The base is squared only while bits of
/// the exponent remain, which means that when squaring overflows, the result it
/// was headed for would have too, so no false overflow is reported.
pub fn intPower(ctx: *Context, base: i64, exponent: i64) Error!i64 {
    if (exponent < 0) return ctx.raiseFmt(
        "an Int cannot be raised to the negative power {d}",
        .{exponent},
        "Make the base a Float, as in `2.0 ** -1`, for a fractional result.",
    );

    var result: i64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining > 0) {
        if (remaining & 1 == 1) {
            const product = @mulWithOverflow(result, factor);
            if (product[1] != 0) return overflow(ctx, .power, base, exponent);
            result = product[0];
        }
        remaining >>= 1;
        if (remaining > 0) {
            const square = @mulWithOverflow(factor, factor);
            if (square[1] != 0) return overflow(ctx, .power, base, exponent);
            factor = square[0];
        }
    }
    return result;
}

/// `left op right` once either operand is a `Float`, and `divide` for any two
/// numbers. Only a zero divisor raises; the rest follows IEEE arithmetic.
pub fn floatArithmetic(ctx: *Context, operator: Arithmetic, left: f64, right: f64) Error!f64 {
    return switch (operator) {
        .add => left + right,
        .subtract => left - right,
        .multiply => left * right,
        .divide => if (right == 0) divisionByZero(ctx, operator) else left / right,
        .floor_divide => if (right == 0) divisionByZero(ctx, operator) else FloatMath.floorDivide(left, right),
        // The result takes the divisor's sign; a NaN or infinite operand gives NaN.
        .remainder => if (right == 0) divisionByZero(ctx, operator) else FloatMath.remainder(left, right),
        .power => FloatMath.power(left, right),
    };
}

/// `-value` for an `Int`. Negating the minimum overflows like any other
/// operation, because the range is asymmetric.
pub fn negate(ctx: *Context, value: i64) Error!i64 {
    const result = @subWithOverflow(@as(i64, 0), value);
    if (result[1] != 0) return ctx.raiseFmt("negating {d} overflows Int", .{value}, integer_range_help);
    return result[0];
}

pub fn overflow(ctx: *Context, operator: Arithmetic, left: i64, right: i64) Error {
    return ctx.raiseFmt("{s} of {d} and {d} overflows Int", .{ operator.describe(), left, right }, integer_range_help);
}

pub fn divisionByZero(ctx: *Context, operator: Arithmetic) Error {
    return ctx.raiseFmt(
        "{s} by zero",
        .{operator.describe()},
        "Check the divisor before dividing. Division by zero has no result for either numeric type.",
    );
}

/// An arithmetic operator given something other than two numbers, which a
/// value of an unannotated type can still reach.
pub fn needsNumbers(ctx: *Context, operator: Arithmetic, left: Value, right: Value) Error {
    return ctx.raiseFmt(
        "{s} needs numbers, but this is {s} and {s}",
        .{ operator.describe(), left.typeName(), right.typeName() },
        "Arithmetic works on Int and Float.",
    );
}

pub fn negateNeedsNumber(ctx: *Context, operand: Value) Error {
    return ctx.raiseFmt("`-` needs a number, but this is {s}", .{operand.typeName()}, "Use `not` to invert a Bool.");
}

pub fn notNeedsBool(ctx: *Context, operand: Value) Error {
    return ctx.raiseFmt(
        "`not` needs a Bool, but this is {s}",
        .{operand.typeName()},
        "Compare it to something first, as in `not (count > 0)`.",
    );
}

pub fn notComparable(ctx: *Context, left: Value, right: Value) Error {
    return ctx.raiseFmt(
        "{s} and {s} cannot be compared",
        .{ left.typeName(), right.typeName() },
        "Comparison needs two values of the same kind.",
    );
}

/// What a position counts in, for an index or a slice.
pub const Collection = enum {
    list,
    string,
    bytes,

    fn name(self: Collection) []const u8 {
        return switch (self) {
            .list => "list",
            .string => "String",
            .bytes => "Bytes",
        };
    }
};

/// Section 5.4: `position` is not an index into `count` items. The message
/// names the index and the valid range. The engine checks the range itself,
/// so a String counts its characters only when this is needed.
pub fn outsideIndex(ctx: *Context, collection: Collection, count: usize, position: i64) Error {
    const subject = switch (collection) {
        .list, .string => collection.name(),
        .bytes => "Bytes value",
    };
    if (count == 0) return ctx.raiseFmt("index {d} is outside this {s}, which is empty", .{ position, subject }, switch (collection) {
        .list => "Check `empty?()` before indexing, or add an element first.",
        .string => "Check `empty?()` before indexing.",
        .bytes => "Check `.count` before indexing, or add bytes first.",
    });
    const unit = switch (collection) {
        .list => "element",
        .string => "character",
        .bytes => "byte",
    };
    const help = try std.fmt.allocPrint(ctx.arena, "Valid indices are 0 through {d}.", .{count - 1});
    return ctx.raiseFmt(
        "index {d} is outside this {s}, which has {d} {s}{s}",
        .{ position, subject, count, unit, if (count == 1) "" else "s" },
        help,
    );
}

/// A slice's positions, `start` up to but not including `end`.
pub const Bounds = struct { start: usize, end: usize };

/// Section 5.4's `collection[start..end]` (or `..=`) over `count` items, where
/// a missing bound is the start or the end of the collection.
pub fn sliceBounds(ctx: *Context, collection: Collection, count: i64, written_start: ?i64, written_end: ?i64, inclusive: bool) Error!Bounds {
    const units = if (collection == .string) "characters" else "elements";
    const start = written_start orelse 0;
    if (start < 0 or start > count) return ctx.raiseFmt(
        "slice start {d} is outside this {s}, which has {d} {s}",
        .{ start, collection.name(), count, units },
        "A slice start may be from 0 through the collection's count.",
    );
    const end = if (written_end) |written| blk: {
        if (written < 0 or written > count or (inclusive and written == count)) return ctx.raiseFmt(
            "slice end {d} is outside this {s}, which has {d} {s}",
            .{ written, collection.name(), count, units },
            if (inclusive) "An inclusive end must name an existing position." else "An exclusive end may equal the collection's count.",
        );
        break :blk if (inclusive) written + 1 else written;
    } else count;
    if (start > end) return ctx.raiseFmt(
        "slice start {d} comes after its end {d}",
        .{ start, written_end orelse count },
        "Write the start at or before the end.",
    );
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Changing `dictionary[key]` in place, as `+=` does, needs an entry there.
pub fn missingKey(ctx: *Context, key: Value) Error {
    var written: std.Io.Writer.Allocating = .init(ctx.arena);
    key.write(&written.writer, true) catch return error.OutOfMemory;
    return ctx.raiseFmt(
        "there is no entry for {s}",
        .{written.written()},
        "Put a value there first, as in `scores[key] = 0`, or check with `contains_key?(key)`.",
    );
}

/// A `Range`'s `count`, which an `Int` cannot hold for every range.
pub fn rangeCount(ctx: *Context, range: *const Range) Error!i64 {
    return range.count() orelse ctx.raise(
        "this Range has too many values for `count`",
        "Use a narrower Range or a larger `step`; an Int count cannot represent every Int value.",
    );
}

/// Reading a name declared without a value before anything assigned one.
pub fn unassigned(ctx: *Context, name: []const u8) Error {
    const help = try std.fmt.allocPrint(ctx.arena, "Assign `{s}` before reading it.", .{name});
    return ctx.raise(try std.fmt.allocPrint(ctx.arena, "`{s}` is not assigned yet", .{name}), help);
}

/// Section 7.2: crossing the call limit raises rather than exhausting the
/// stack. `at_limit` tells reaching the 1,000-call guarantee from running out
/// of stack before it, which only a pathologically nested body can do.
pub fn tooMuchRecursion(ctx: *Context, function: []const u8, at_limit: bool) Error {
    // A program's own names never hold a space; a description such as "the
    // constructor of `Node`" or "a block" already reads as prose.
    const quote = if (std.mem.indexOfScalar(u8, function, ' ') == null) "`" else "";
    return ctx.raiseTyped(
        "RecursionError",
        try std.fmt.allocPrint(ctx.arena, "too much recursion calling {s}{s}{s}", .{ quote, function, quote }),
        if (at_limit)
            "Emerald supports at least 1,000 active calls. Check that the recursion has a case that stops it."
        else
            "These calls nest too deeply for the stack available. Check that the recursion has a case that stops it.",
    );
}

/// Running out of stack with no call active to blame, as an expression or
/// block nested thousands deep at the top of a file can.
pub fn nestedTooDeeply(ctx: *Context) Error {
    return ctx.raise("this is nested too deeply to run", "Break the expression or block into smaller named pieces.");
}

test "an index outside a list names the valid range" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // These messages need only the arena; the rest is for natives that build
    // values or call back into the engine.
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .heap = undefined,
        .io = undefined,
        .state = undefined,
        .engine = undefined,
    };
    try std.testing.expectEqual(error.Raised, outsideIndex(&ctx, .list, 2, 2));
    try std.testing.expectEqualStrings("index 2 is outside this list, which has 2 elements", ctx.failure.?.message);
    try std.testing.expectEqualStrings("Valid indices are 0 through 1.", ctx.failure.?.help);
    try std.testing.expectError(error.Raised, intArithmetic(&ctx, .add, std.math.maxInt(i64), 1));
    try std.testing.expectEqualStrings("addition of 9223372036854775807 and 1 overflows Int", ctx.failure.?.message);
}
