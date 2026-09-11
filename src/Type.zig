//! Static types.
//!
//! Section 4.1 requires every expression to have a type before execution. Only
//! the built-in scalars exist so far; optionals, collections, and user types
//! arrive with their own slices, which is why this is an enum rather than a
//! structured representation.

const std = @import("std");

const Type = @This();

pub const Kind = enum {
    nothing,
    bool,
    int,
    float,
    /// A type that could not be determined because something was already
    /// reported. It is compatible with everything, so one mistake produces one
    /// diagnostic instead of a cascade through every expression containing it.
    invalid,
};

kind: Kind,

/// A function's checked shape: each parameter's type, its name for diagnostics
/// that name a mismatched one, and the return type, whether written or
/// inferred.
///
/// Not a `Type` itself. No value of function type can be formed yet — bare
/// function references and lambdas are both deferred — so there is no
/// assignability question a structural function type would have to answer.
///
/// The interpreter reads these too, because section 4.4's widening has to
/// happen at runtime wherever the checker allowed it: an `Int` passed to a
/// `Float` parameter, or returned from a function whose return type is `Float`,
/// including one the checker inferred.
pub const Signature = struct {
    parameters: []const Type,
    parameter_names: []const []const u8,
    return_type: Type,
};

pub const Signatures = std.StringHashMapUnmanaged(Signature);

pub const nothing: Type = .{ .kind = .nothing };
pub const @"bool": Type = .{ .kind = .bool };
pub const int: Type = .{ .kind = .int };
pub const float: Type = .{ .kind = .float };
pub const invalid: Type = .{ .kind = .invalid };

/// The name a program writes for this type, and the name diagnostics use.
pub fn name(self: Type) []const u8 {
    return switch (self.kind) {
        .nothing => "Nothing",
        .bool => "Bool",
        .int => "Int",
        .float => "Float",
        .invalid => "an unknown type",
    };
}

pub fn fromName(text: []const u8) ?Type {
    if (std.mem.eql(u8, text, "Nothing")) return nothing;
    if (std.mem.eql(u8, text, "Bool")) return @"bool";
    if (std.mem.eql(u8, text, "Int")) return int;
    if (std.mem.eql(u8, text, "Float")) return float;
    return null;
}

pub fn isNumber(self: Type) bool {
    return switch (self.kind) {
        .int, .float => true,
        .nothing, .bool, .invalid => false,
    };
}

/// Whether a value of this type may be used where `target` is expected.
///
/// Section 4.4 allows numeric widening from `Int` to `Float`. It describes the
/// allowance as applying "where arithmetic requires it", but the same section
/// also relies on it to infer `[Float]` for `[1, 2.5]`, which is not arithmetic.
/// The rule is read here as applying wherever a value meets an expected numeric
/// type, so `var rate: Float = 1` is accepted. Narrowing never is.
pub fn assignableTo(self: Type, target: Type) bool {
    if (self.kind == .invalid or target.kind == .invalid) return true;
    if (self.kind == target.kind) return true;
    return self.kind == .int and target.kind == .float;
}

/// The type of an arithmetic result, given both operand types, or null when the
/// operands are not numbers.
///
/// Section 5.3 fixes these: `/` and `**` always produce a `Float`, while the
/// others produce an `Int` only when both operands are `Int`.
pub fn arithmeticResult(left: Type, right: Type, always_float: bool) ?Type {
    if (left.kind == .invalid or right.kind == .invalid) return invalid;
    if (!left.isNumber() or !right.isNumber()) return null;
    if (always_float) return float;
    if (left.kind == .int and right.kind == .int) return int;
    return float;
}

const testing = std.testing;

test "a type is assignable to itself" {
    try testing.expect(Type.int.assignableTo(.int));
    try testing.expect(Type.bool.assignableTo(.bool));
    try testing.expect(Type.nothing.assignableTo(.nothing));
}

test "Int widens to Float but Float does not narrow" {
    try testing.expect(Type.int.assignableTo(.float));
    try testing.expect(!Type.float.assignableTo(.int));
}

test "unrelated types are not assignable" {
    try testing.expect(!Type.bool.assignableTo(.int));
    try testing.expect(!Type.int.assignableTo(.bool));
    try testing.expect(!Type.nothing.assignableTo(.int));
}

test "an invalid type is compatible with everything so errors do not cascade" {
    try testing.expect(Type.invalid.assignableTo(.int));
    try testing.expect(Type.int.assignableTo(.invalid));
}

test "arithmetic keeps Int only when both operands are Int" {
    try testing.expectEqual(Type.Kind.int, Type.arithmeticResult(.int, .int, false).?.kind);
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.int, .float, false).?.kind);
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.float, .float, false).?.kind);
    // `/` and `**` produce a Float even for two Ints.
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.int, .int, true).?.kind);
    try testing.expect(Type.arithmeticResult(.bool, .int, false) == null);
}

test "type names round-trip through their source spelling" {
    try testing.expectEqual(Type.Kind.int, Type.fromName("Int").?.kind);
    try testing.expectEqual(Type.Kind.float, Type.fromName("Float").?.kind);
    try testing.expectEqual(Type.Kind.bool, Type.fromName("Bool").?.kind);
    try testing.expectEqual(Type.Kind.nothing, Type.fromName("Nothing").?.kind);
    try testing.expect(Type.fromName("Player") == null);
    try testing.expectEqualStrings("Int", Type.int.name());
}
