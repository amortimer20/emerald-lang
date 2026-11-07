//! Section 6.4's `Range` methods, as natives (`Native.zig`).

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

/// Every `Range` method these natives answer, by name.
pub const Method = enum {
    @"empty?",
    step,
    reverse,
    to_list,
};

pub fn rangeMethod(ctx: *Context, range: Range, method: Method, arguments: []const Value) Error!Value {
    return switch (method) {
        .@"empty?" => .initBool(range.empty()),
        .step => blk: {
            const distance = arguments[0].data.int;
            if (distance < 1) return ctx.raiseFmt(
                "a step must be at least 1, but this is {d}",
                .{distance},
                "The range says which way to count; the step says only how far, as in `10.down_to(0).step(2)`.",
            );
            break :blk .{ .data = .{ .range = range.step(distance) } };
        },
        .reverse => .{ .data = .{ .range = range.reverse() } },
        .to_list => blk: {
            const items = range.toList(ctx.gpa) catch |err| switch (err) {
                error.RangeTooLarge => return ctx.raise(
                    "this Range is too large to turn into a List",
                    "Use a narrower Range or a larger `step` before calling `to_list()`.",
                ),
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer if (items.len > 0) ctx.gpa.free(items);
            const list = try ctx.heap.createList(.int, items.len);
            const result: Value = .{ .data = .{ .list = list } };
            errdefer ctx.heap.release(result);
            for (items) |item| list.items.appendAssumeCapacity(.initInt(item));
            break :blk result;
        },
    };
}
