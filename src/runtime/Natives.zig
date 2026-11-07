//! The table of runtime natives (docs/compiler-design-plan.md, decision 4): one
//! id for each method a native answers, and one way to call it. The interpreter
//! looks an id up from a method's name; a compiled program will emit the id.

const std = @import("std");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const StringMethods = @import("StringMethods.zig");
const BytesMethods = @import("BytesMethods.zig");
const NumberMethods = @import("NumberMethods.zig");
const RangeMethods = @import("RangeMethods.zig");
const ListMethods = @import("ListMethods.zig");
const MapMethods = @import("MapMethods.zig");

/// A native, named by the kind of its receiver and the method.
pub const Id = union(enum) {
    string: StringMethods.Method,
    bytes: BytesMethods.Method,
    int: NumberMethods.IntMethod,
    float: NumberMethods.FloatMethod,
    range: RangeMethods.Method,
    list: ListMethods.Method,
    map: MapMethods.Method,
};

pub const Family = std.meta.Tag(Id);

/// The id of `family`'s method called `name`, or null if no native answers it.
pub fn lookup(comptime family: Family, name: []const u8) ?Id {
    const Method = @FieldType(Id, @tagName(family));
    const method = std.meta.stringToEnum(Method, name) orelse return null;
    return @unionInit(Id, @tagName(family), method);
}

/// Runs native `id` on `receiver`, which has the kind its family names.
pub fn call(ctx: *Native.Context, id: Id, receiver: Value, arguments: []const Value) Native.Error!Value {
    return switch (id) {
        .string => |method| StringMethods.stringMethod(ctx, receiver.data.string.bytes, method, arguments),
        .bytes => |method| BytesMethods.bytesMethod(ctx, receiver.data.bytes.bytes, method),
        .int => |method| NumberMethods.intMethod(ctx, receiver.data.int, method, arguments),
        .float => |method| NumberMethods.floatMethod(ctx, receiver.data.float, method, arguments),
        .range => |method| RangeMethods.rangeMethod(ctx, receiver.data.range, method, arguments),
        .list => |method| ListMethods.readListMethod(ctx, receiver.data.list, method, arguments),
        .map => |method| MapMethods.readMap(ctx, method, receiver.data.map, arguments),
    };
}

test "every family's methods have ids, and lookups find them" {
    try std.testing.expectEqual(Id{ .string = .upper }, lookup(.string, "upper").?);
    try std.testing.expectEqual(Id{ .map = .@"contains_key?" }, lookup(.map, "contains_key?").?);
    try std.testing.expect(lookup(.list, "no_such_method") == null);
}
