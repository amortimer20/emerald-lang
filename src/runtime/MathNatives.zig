//! Section 9.3's `Math` functions as natives (`Native.zig`).

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const FloatMath = @import("FloatMath.zig");
const ListMethods = @import("ListMethods.zig");

const Context = Native.Context;
const Error = Native.Error;
const widen = Native.widen;
const toFloat = Native.toFloat;

/// Every `Math` function, by name.
pub const Function = enum { sin, cos, tan, arc_sin, arc_cos, arc_tan, arc_tan2, natural_log, log10, log, power, min, max };

/// `Math.name(arguments)`. `min` and `max` give back one of their arguments,
/// which the caller still owns; the rest give a new `Float`.
pub fn call(ctx: *Context, name: []const u8, arguments: []const Value) Error!Value {
    const function = std.meta.stringToEnum(Function, name).?;
    if (function == .min or function == .max) return extreme(ctx, function == .min, arguments[0], arguments[1]);
    var values: [2]f64 = undefined;
    for (arguments, 0..) |argument, index| values[index] = toFloat(argument);
    return .initFloat(switch (function) {
        .sin => std.math.sin(values[0]),
        .cos => std.math.cos(values[0]),
        .tan => std.math.tan(values[0]),
        .arc_sin => std.math.asin(values[0]),
        .arc_cos => std.math.acos(values[0]),
        .arc_tan => std.math.atan(values[0]),
        .arc_tan2 => std.math.atan2(values[0], values[1]),
        .natural_log => std.math.log(f64, std.math.e, values[0]),
        .log10 => std.math.log10(values[0]),
        .log => if (values[1] <= 0 or values[1] == 1) std.math.nan(f64) else std.math.log(f64, values[1], values[0]),
        .power => FloatMath.power(values[0], values[1]),
        .min, .max => unreachable,
    });
}

/// `Math.min` and `Math.max`: one of the two, an `Int` widened when the other
/// is a `Float`, retained for the caller.
fn extreme(ctx: *Context, minimum: bool, left: Value, right: Value) Error!Value {
    var first = left;
    var second = right;
    if (first.data == .float or second.data == .float) {
        first = widen(first, .float);
        second = widen(second, .float);
        if (std.math.isNan(first.data.float) or std.math.isNan(second.data.float)) return ctx.raiseFmt(
            "`Math.{s}` cannot compare NaN",
            .{if (minimum) "min" else "max"},
            "Check values with `nan?()` before choosing a minimum or maximum.",
        );
    }
    const ordering = try ListMethods.orderListItems(ctx, first.data, first, second, .ordinary);
    const take_second = if (minimum) ordering == .gt else ordering == .lt;
    return Heap.retain(if (take_second) second else first);
}
