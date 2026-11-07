//! `Bytes` methods (15.12), as natives (`Native.zig`).

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

/// Every `Bytes` method these natives answer, by name.
pub const Method = enum { to_string_maybe, to_hex, to_string };

pub fn bytesMethod(ctx: *Context, bytes: []const u8, method: Method) Error!Value {
    if (method == .to_string_maybe) {
        return if (std.unicode.utf8ValidateSlice(bytes)) ctx.heap.copyText(bytes) else Value.nothing;
    }
    if (method == .to_hex) return bytesToHex(ctx.heap, bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return raiseEncodingMessage(ctx, "these Bytes are not valid UTF-8 text");
    return ctx.heap.copyText(bytes);
}

fn bytesToHex(heap: *Heap, bytes: []const u8) std.mem.Allocator.Error!Value {
    const length = std.math.mul(usize, bytes.len, 2) catch return error.OutOfMemory;
    const out = try heap.gpa.alloc(u8, length);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0x0f];
    }
    return .{ .data = .{ .string = try heap.createText(out) } };
}

/// Section 15.3's `Bytes.from_list`: each `Int` must be a byte.
pub fn fromList(ctx: *Context, numbers: []const Value) Error!Value {
    const bytes = try ctx.gpa.alloc(u8, numbers.len);
    for (numbers, bytes) |number, *byte| {
        if (number.data.int < 0 or number.data.int > 255) {
            ctx.gpa.free(bytes);
            return ctx.raiseFmt("a byte must be from 0 to 255, but this is {d}", .{number.data.int}, "Pass whole numbers from 0 through 255.");
        }
        byte.* = @intCast(number.data.int);
    }
    return .{ .data = .{ .bytes = try ctx.heap.createText(bytes) } };
}

pub fn raiseEncodingMessage(ctx: *Context, message: []const u8) Error {
    return ctx.raiseTyped("EncodingError", message, "Check that this text uses the expected encoding.");
}
