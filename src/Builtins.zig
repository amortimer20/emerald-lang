//! Learner-facing descriptions, not typing rules. Only editor requests and
//! parity tests load this data; ordinary programs never parse it.
const std = @import("std");

pub const Parameter = struct {
    name: []const u8,
    type: []const u8,
    default: ?[]const u8 = null,
    optional: bool = false,
    variadic: bool = false,
};

pub const Signature = struct {
    parameters: []const Parameter = &.{},
    block: ?[]const u8 = null,
    result: []const u8,
    summary: []const u8,
    raises: bool = false,
    page: []const u8,
};

pub const Kind = enum { method, property, type_method, type_property, function, statement };
pub const Member = struct {
    owner: ?[]const u8,
    name: []const u8,
    kind: Kind,
    changes: bool = false,
    signatures: []const Signature,
};

pub const Data = struct {
    version: u32,
    about: []const u8,
    members: []const Member,
};

pub const Catalog = std.json.Parsed(Data);

pub fn load(gpa: std.mem.Allocator) error{OutOfMemory}!Catalog {
    const parsed = std.json.parseFromSlice(Data, gpa, @embedFile("builtins.json"), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("Emerald's built-in member data is invalid"),
    };
    if (parsed.value.version != 1) @panic("Emerald's built-in member data version is unsupported");
    return parsed;
}

pub fn find(data: Data, owner: ?[]const u8, name: []const u8) ?Member {
    for (data.members) |member| {
        if (sameOwner(member.owner, owner) and std.mem.eql(u8, member.name, name)) return member;
    }
    return null;
}

pub fn sameOwner(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "the catalog owns its parsed descriptions and rejects duplicate members" {
    const catalog = try load(std.testing.allocator);
    defer catalog.deinit();
    for (catalog.value.members, 0..) |member, index| {
        try std.testing.expect(member.signatures.len != 0);
        for (catalog.value.members[0..index]) |earlier| {
            try std.testing.expect(!(sameOwner(earlier.owner, member.owner) and std.mem.eql(u8, earlier.name, member.name)));
        }
    }
}
