//! Static types.
//!
//! Section 4.1 requires every expression to have a type before execution. The
//! built-in scalars are plain kinds; a list carries its element type, allocated
//! by whoever builds it, so `[[Int]]` is a list whose element is `[Int]`.
//! Optionals, the other collections, and user types arrive with their slices.
//!
//! Types print through `format`, so a diagnostic writes `{f}` and gets the
//! spelling a program would write, such as `[Float]`.

const std = @import("std");

const Type = @This();

pub const Kind = enum {
    nothing,
    bool,
    int,
    float,
    /// Section 9's immutable, Unicode-aware text.
    string,
    /// Section 8.2's `[T]`. `element` holds `T`.
    list,
    /// Section 7.1's `func(Int): String`. `signature` holds its shape.
    function,
    /// A type that could not be determined because something was already
    /// reported. It is compatible with everything, so one mistake produces one
    /// diagnostic instead of a cascade through every expression containing it.
    invalid,
};

kind: Kind,
/// The element type of a list, and null for every other kind.
element: ?*const Type = null,
/// What a function takes and gives, and null for every other kind.
signature: ?*const Signature = null,
/// Section 4.2's trailing `?`: this value may be absent.
///
/// A flag rather than a wrapping kind, because section 4.5 settles that
/// optionals never nest. There is nothing for a second layer to mean, so there
/// is no way to build one by accident, and `Int?` stays as cheap to carry
/// around as `Int`. Placement is still structural: this flag on a list is
/// `[String]?`, while the same flag on its element is `[String?]`.
optional: bool = false,

/// A function's checked shape: each parameter's type, its name for diagnostics
/// that name a mismatched one, and the return type, whether written or
/// inferred.
///
/// This is also what a `.function` type points at, so a named function and a
/// lambda with the same shape have the same type: nothing about a callable's
/// type depends on where it came from.
///
/// The interpreter reads these too, because section 4.4's widening has to
/// happen at runtime wherever the checker allowed it: an `Int` passed to a
/// `Float` parameter, or returned from a function whose return type is `Float`,
/// including one the checker inferred.
pub const Signature = struct {
    parameters: []const Type,
    /// Empty for a signature that came from a type annotation, which writes no
    /// names.
    parameter_names: []const []const u8 = &.{},
    return_type: Type,
};

pub const Signatures = std.StringHashMapUnmanaged(Signature);

pub const nothing: Type = .{ .kind = .nothing };
pub const @"bool": Type = .{ .kind = .bool };
pub const int: Type = .{ .kind = .int };
pub const float: Type = .{ .kind = .float };
pub const string: Type = .{ .kind = .string };
pub const invalid: Type = .{ .kind = .invalid };

/// `[element]`, with the element allocated from `allocator`, which must outlive
/// the result.
pub fn listOf(allocator: std.mem.Allocator, element: Type) std.mem.Allocator.Error!Type {
    const stored = try allocator.create(Type);
    stored.* = element;
    return .{ .kind = .list, .element = stored };
}

/// `func(...)`, with the signature allocated from `allocator`, which must
/// outlive the result.
pub fn functionOf(allocator: std.mem.Allocator, signature: Signature) std.mem.Allocator.Error!Type {
    const stored = try allocator.create(Signature);
    stored.* = signature;
    return .{ .kind = .function, .signature = stored };
}

/// Section 4.5: applying an optional-producing operation to something already
/// optional yields the same type rather than a second layer.
pub fn optionalOf(self: Type) Type {
    var result = self;
    result.optional = true;
    return result;
}

/// What an optional holds when it is present. Unchanged for a type that is not
/// optional.
pub fn payload(self: Type) Type {
    var result = self;
    result.optional = false;
    return result;
}

/// Writes the name a program writes for this type, which is also the name
/// diagnostics use.
pub fn format(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.optional) {
        try self.payload().format(writer);
        return writer.writeAll("?");
    }
    switch (self.kind) {
        .nothing => try writer.writeAll("Nothing"),
        .bool => try writer.writeAll("Bool"),
        .int => try writer.writeAll("Int"),
        .float => try writer.writeAll("Float"),
        .string => try writer.writeAll("String"),
        .list => try writer.print("[{f}]", .{self.element.?.*}),
        // Section 7.1: the return type is written only when there is one, so a
        // function with no result is `func(Int)` rather than `func(Int): Nothing`.
        .function => {
            const signature = self.signature.?;
            try writer.writeAll("func(");
            for (signature.parameters, 0..) |parameter, position| {
                if (position != 0) try writer.writeAll(", ");
                try writer.print("{f}", .{parameter});
            }
            try writer.writeAll(")");
            if (signature.return_type.kind != .nothing) {
                try writer.print(": {f}", .{signature.return_type});
            }
        },
        .invalid => try writer.writeAll("an unknown type"),
    }
}

pub fn fromName(text: []const u8) ?Type {
    if (std.mem.eql(u8, text, "Nothing")) return nothing;
    if (std.mem.eql(u8, text, "Bool")) return @"bool";
    if (std.mem.eql(u8, text, "Int")) return int;
    if (std.mem.eql(u8, text, "Float")) return float;
    if (std.mem.eql(u8, text, "String")) return string;
    return null;
}

/// Whether arithmetic and ordering apply. An optional number is not one: it may
/// be absent, so it has to be narrowed or given a fallback first.
pub fn isNumber(self: Type) bool {
    if (self.optional) return false;
    return switch (self.kind) {
        .int, .float => true,
        .nothing, .bool, .string, .list, .function, .invalid => false,
    };
}

/// Whether the type is, or contains, one that could not be determined.
pub fn isInvalid(self: Type) bool {
    return switch (self.kind) {
        .invalid => true,
        .list => self.element.?.isInvalid(),
        .function => blk: {
            const signature = self.signature.?;
            for (signature.parameters) |parameter| {
                if (parameter.isInvalid()) break :blk true;
            }
            break :blk signature.return_type.isInvalid();
        },
        else => false,
    };
}

/// Structural equality, under which an undetermined part matches anything so
/// that one mistake does not produce a second report.
pub fn same(self: Type, other: Type) bool {
    if (self.kind == .invalid or other.kind == .invalid) return true;
    if (self.optional != other.optional) return false;
    if (self.kind != other.kind) return false;
    if (self.kind == .list) return self.element.?.same(other.element.?.*);
    if (self.kind == .function) {
        const mine = self.signature.?;
        const theirs = other.signature.?;
        if (mine.parameters.len != theirs.parameters.len) return false;
        for (mine.parameters, theirs.parameters) |a, b| {
            if (!a.same(b)) return false;
        }
        return mine.return_type.same(theirs.return_type);
    }
    return true;
}

/// Whether a value of this type may be used where `target` is expected.
///
/// Section 4.4 widens `Int` to `Float` wherever a `Float` is expected. Lists are
/// invariant (4.4): `[Int]` is not a `[Float]`, because a list is mutable and
/// its elements would have to change type to become one. A list literal can
/// still be built as `[Float]` from whole numbers, because the checker gives it
/// the expected element type before its elements are stored.
///
/// Functions are invariant too. Parameter and result variance is a real rule
/// with a real explanation, and it earns its place only once there is a type
/// hierarchy to vary over; until then an exact match is both sound and the
/// easier thing to teach.
pub fn assignableTo(self: Type, target: Type) bool {
    if (self.kind == .invalid or target.kind == .invalid) return true;

    // Section 4.2: `nothing` is the absent value of every optional type, and a
    // present value may be used where a possibly-absent one is expected. The
    // reverse is not true, which is the whole point of the marker.
    if (target.optional) {
        if (self.kind == .nothing) return true;
        return self.payload().assignableTo(target.payload());
    }
    if (self.optional) return false;

    if (self.kind == .int and target.kind == .float) return true;
    return self.same(target);
}

/// What a list method takes and gives, in terms of the list's element type.
/// Section 8.5's essential vocabulary, less `first` and `last`, which wait for
/// optionals. `each` and `map` take a block, whose type depends on the
/// receiver's element type, so the checker handles those two directly.
pub const ListMethod = struct {
    parameters: []const Operand,
    result: Result,
    /// Whether it changes the list it is called on, which a `const`, a
    /// parameter, a loop variable, or a temporary value cannot allow (4.3, 7.1).
    mutates: bool,

    pub const Operand = enum { element, index };
    pub const Result = enum { nothing, bool, element };
};

pub const list_methods = std.StaticStringMap(ListMethod).initComptime(.{
    .{ "append", ListMethod{ .parameters = &.{.element}, .result = .nothing, .mutates = true } },
    .{ "insert", ListMethod{ .parameters = &.{ .index, .element }, .result = .nothing, .mutates = true } },
    .{ "remove", ListMethod{ .parameters = &.{.element}, .result = .nothing, .mutates = true } },
    .{ "remove_all", ListMethod{ .parameters = &.{.element}, .result = .nothing, .mutates = true } },
    .{ "remove_at", ListMethod{ .parameters = &.{.index}, .result = .element, .mutates = true } },
    .{ "remove_first", ListMethod{ .parameters = &.{}, .result = .element, .mutates = true } },
    .{ "remove_last", ListMethod{ .parameters = &.{}, .result = .element, .mutates = true } },
    .{ "clear", ListMethod{ .parameters = &.{}, .result = .nothing, .mutates = true } },
    .{ "contains?", ListMethod{ .parameters = &.{.element}, .result = .bool, .mutates = false } },
    .{ "empty?", ListMethod{ .parameters = &.{}, .result = .bool, .mutates = false } },
});

/// What a `String` method takes and gives. Section 9.2's vocabulary, less what
/// is deferred there. `maybe` marks the ones whose answer may be absent (4.5).
pub const StringMethod = struct {
    parameters: []const Operand,
    /// How many trailing parameters may be left out: `substring(start)` and
    /// `substring(start, count)` are one method.
    optional: u8 = 0,
    result: Result,
    /// Whether the result may be absent, which section 4.5 marks with `?`.
    maybe: bool = false,

    pub const Operand = enum { string, int, float };
    pub const Result = enum { bool, int, float, string, strings };
};

pub const string_methods = std.StaticStringMap(StringMethod).initComptime(.{
    .{ "empty?", StringMethod{ .parameters = &.{}, .result = .bool } },
    .{ "blank?", StringMethod{ .parameters = &.{}, .result = .bool } },
    .{ "contains?", StringMethod{ .parameters = &.{.string}, .result = .bool } },
    .{ "starts_with?", StringMethod{ .parameters = &.{.string}, .result = .bool } },
    .{ "ends_with?", StringMethod{ .parameters = &.{.string}, .result = .bool } },
    .{ "trim", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "trim_start", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "trim_end", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "upper", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "lower", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "capitalize", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "reverse", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "repeat", StringMethod{ .parameters = &.{.int}, .result = .string } },
    .{ "replace", StringMethod{ .parameters = &.{ .string, .string }, .result = .string } },
    .{ "substring", StringMethod{ .parameters = &.{ .int, .int }, .optional = 1, .result = .string } },
    .{ "split", StringMethod{ .parameters = &.{.string}, .result = .strings } },
    .{ "lines", StringMethod{ .parameters = &.{}, .result = .strings } },
    .{ "chars", StringMethod{ .parameters = &.{}, .result = .strings } },
    .{ "index_of", StringMethod{ .parameters = &.{.string}, .result = .int, .maybe = true } },
    .{ "to_int", StringMethod{ .parameters = &.{}, .result = .int } },
    .{ "to_int_maybe", StringMethod{ .parameters = &.{}, .result = .int, .maybe = true } },
    .{ "to_float_maybe", StringMethod{ .parameters = &.{}, .result = .float, .maybe = true } },
    .{ "to_int_or", StringMethod{ .parameters = &.{.int}, .result = .int } },
    .{ "to_float", StringMethod{ .parameters = &.{}, .result = .float } },
    .{ "to_float_or", StringMethod{ .parameters = &.{.float}, .result = .float } },
});

/// The type of an arithmetic result, given both operand types, or null when the
/// operands are not numbers.
///
/// Section 5.3 fixes these: `/` always produces a `Float`, while the others
/// produce an `Int` only when both operands are `Int`.
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

test "lists are invariant, so an Int list is not a Float list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ints = try Type.listOf(arena, .int);
    const floats = try Type.listOf(arena, .float);
    try testing.expect(ints.assignableTo(ints));
    try testing.expect(!ints.assignableTo(floats));
    try testing.expect(!floats.assignableTo(ints));
    try testing.expect(!ints.assignableTo(.int));
    try testing.expect(ints.assignableTo(try Type.listOf(arena, .invalid)));
}

test "arithmetic keeps Int only when both operands are Int" {
    try testing.expectEqual(Type.Kind.int, Type.arithmeticResult(.int, .int, false).?.kind);
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.int, .float, false).?.kind);
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.float, .float, false).?.kind);
    // `/` produces a Float even for two Ints.
    try testing.expectEqual(Type.Kind.float, Type.arithmeticResult(.int, .int, true).?.kind);
    try testing.expect(Type.arithmeticResult(.bool, .int, false) == null);
}

test "types print with their source spelling" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nested = try Type.listOf(arena, try Type.listOf(arena, .float));
    try testing.expectEqualStrings("[[Float]]", try std.fmt.allocPrint(arena, "{f}", .{nested}));
    try testing.expectEqualStrings("Int", try std.fmt.allocPrint(arena, "{f}", .{Type.int}));
}

test "type names round-trip through their source spelling" {
    try testing.expectEqual(Type.Kind.int, Type.fromName("Int").?.kind);
    try testing.expectEqual(Type.Kind.float, Type.fromName("Float").?.kind);
    try testing.expectEqual(Type.Kind.bool, Type.fromName("Bool").?.kind);
    try testing.expectEqual(Type.Kind.nothing, Type.fromName("Nothing").?.kind);
    try testing.expect(Type.fromName("Player") == null);
}
