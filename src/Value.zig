//! Runtime values and how they display.
//!
//! `Nothing`, `Bool`, `Int`, `Float`, and lists exist so far. Section 4.2
//! settles the numeric widths as language semantics rather than host details:
//! `Int` is 64-bit signed and `Float` is IEEE-754 binary64, and every backend
//! must agree.
//!
//! A list or tuple is a reference to a counted object in `Heap`, so copying a `Value`
//! is cheap, but only `Heap.retain` records that the copy exists. See `Heap`
//! for the rules that keep section 8.1's value semantics intact.

const std = @import("std");
const Heap = @import("Heap.zig");
const Range = @import("Range.zig").Range;
const unicode = @import("unicode.zig");

const Value = @This();

pub const Kind = enum { nothing, bool, int, float, string, range, list, tuple, map, closure, struct_value };

data: Data,

pub const Data = union(Kind) {
    /// Section 4.2's absence-only type. Its single value is written `nothing`.
    nothing: void,
    bool: bool,
    int: i64,
    float: f64,
    string: *Heap.Text,
    /// Section 6.4's immutable integer range value.
    range: Range,
    list: *Heap.List,
    /// Section 8.2's `("score", 10)`, which never changes once built.
    tuple: *Heap.Tuple,
    /// Section 8.2's dictionary or set, which share one structure.
    map: *Heap.Map,
    /// Section 7.4's lambda, or section 7.5's captured function.
    closure: *Heap.Closure,
    /// Section 10.1's value-type instance. The heap keeps copying cheap until
    /// a later field mutation needs its own buffer.
    struct_value: *Heap.StructValue,
};

pub const StructType = struct {
    /// Program-wide identity used for hashing and runtime lookup.
    name: []const u8,
    /// The declaration spelling used when displaying a value. A private
    /// type's resolved key contains its file path and cannot be shortened by
    /// splitting on a namespace dot.
    display_name: []const u8,
    /// Section 10.1: an instance of a class is one shared object, changed in
    /// place and compared by identity.
    class: bool = false,
    fields: []const Field,
    /// Field names are resolved when the descriptor is built, rather than at
    /// every interpreted read or write. Kept alongside `fields` because the
    /// numeric result is that slice's layout position.
    field_positions: std.StringHashMapUnmanaged(usize) = .empty,
    /// Section 10.3's computed properties, which store nothing and so are
    /// neither displayed nor compared. Each names the functions that run it:
    /// for a class, the nearest version to the object's own class (10.7).
    properties: []const Property = &.{},
    /// Section 10.7: how many classes this one extends, counting through its
    /// base classes. A class that extends none is 0.
    depth: u32 = 0,
    /// For a class that extends another or is extended, the method each name
    /// runs on an object of exactly this class: its own, or the nearest base
    /// class's. Null for every other type, whose methods are the ones called.
    methods: ?*const Methods = null,
    /// Section 10.7's base class, for a class that extends one.
    base: ?*const StructType = null,
    /// Section 11.2: the key of every trait this type adopts, directly,
    /// through other traits, or through its base classes.
    traits: []const []const u8 = &.{},
    /// Section 12: an enum's values, in the order it lists them. Empty for
    /// every other type.
    values: []const []const u8 = &.{},

    /// Whether a value of this type is also one of the type named `key`: this
    /// type, one it extends, or a trait it adopts (4.4).
    pub fn isOrExtends(self: *const StructType, key: []const u8) bool {
        var at: ?*const StructType = self;
        while (at) |current| : (at = current.base) {
            if (std.mem.eql(u8, current.name, key)) return true;
        }
        for (self.traits) |trait| {
            if (std.mem.eql(u8, trait, key)) return true;
        }
        return false;
    }

    pub const Field = struct {
        name: []const u8,
        kind: Kind,
    };

    /// The layout position of a stored field. Runtime descriptors are built
    /// from `Type.User.fields`, so this is the same order the checker uses.
    pub fn fieldPosition(self: *const StructType, name: []const u8) ?usize {
        return self.field_positions.get(name);
    }

    pub const Property = struct {
        name: []const u8,
        getter: []const u8,
        setter: ?[]const u8,
        /// The `depth` of the class that declares this version.
        depth: u32 = 0,
        owner: []const u8 = "",
    };

    pub const Methods = std.StringHashMapUnmanaged(Method);

    pub const Method = struct {
        key: []const u8,
        /// The `depth` of the class that declares this version, and its name
        /// as a reader writes it.
        depth: u32,
        owner: []const u8,
    };

    pub fn property(self: *const StructType, name: []const u8) ?Property {
        for (self.properties) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub const nothing: Value = .{ .data = .nothing };

/// The class instances `write` is inside of, outermost first.
threadlocal var displaying: [256]*const Heap.StructValue = undefined;
threadlocal var displaying_count: usize = 0;

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
///
/// A list's element type is static and not carried at runtime, so a list is
/// described only as a list. This appears only in safety-net errors the checker
/// already rules out.
pub fn typeName(self: Value) []const u8 {
    return switch (self.data) {
        .nothing => "Nothing",
        .bool => "Bool",
        .int => "Int",
        .float => "Float",
        .string => "String",
        .range => "Range",
        .list => "a list",
        .tuple => "a tuple",
        .map => |map| if (map.is_set) "a set" else "a dictionary",
        .closure => "a function",
        .struct_value => |instance| instance.descriptor.display_name,
    };
}

/// Whether two values are numbers, which is what arithmetic and ordering need.
pub fn isNumber(self: Value) bool {
    return switch (self.data) {
        .nothing, .bool, .string, .range, .list, .tuple, .map, .closure, .struct_value => false,
        .int, .float => true,
    };
}

/// Writes the value as `print` and interpolation would. A string is its text.
/// A list writes its elements between brackets, separated by a comma and a
/// space, the way they would be written in source: `[1, 2, 3]`, and
/// `["Ava", "Noah"]` with each string quoted, so `["a, b"]` and `["a", "b"]`
/// cannot be mistaken for each other.
///
/// A function has no written form, so it displays as something that is
/// obviously not one: `<func greet>` for a named function, `<lambda>` for one
/// written inline.
pub fn display(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return self.writeThrough(writer, false, {});
}

/// The value as it would be written inside a collection: a string is quoted,
/// so `["a, b"]` and `["a", "b"]` cannot be mistaken for each other.
pub fn write(self: Value, writer: *std.Io.Writer, quoted: bool) std.Io.Writer.Error!void {
    return self.writeThrough(writer, quoted, {});
}

/// `write`, resolving section 15.1's `Textual` through `textual`: either `{}`,
/// which writes every value's plain form, or a context with a `writeTextual`
/// method that renders a value adopting the trait through its own
/// `to_string()` and answers whether it did.
///
/// The context is threaded through the whole walk, so an adopting value
/// renders the same way nested inside a collection as it does alone. Only
/// `print`, `write`, and interpolation supply one; diagnostic text passes `{}`
/// so that building a failure never runs a program's own code.
pub fn writeThrough(self: Value, writer: *std.Io.Writer, quoted: bool, textual: anytype) !void {
    switch (self.data) {
        .nothing => try writer.writeAll("nothing"),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .int => |value| try writer.print("{d}", .{value}),
        .float => |value| try displayFloat(value, writer),
        .string => |text| if (quoted) try writeQuoted(text.bytes, writer) else try writer.writeAll(text.bytes),
        .range => |range| {
            if (range.is_empty) {
                try writer.writeAll("[]");
                return;
            }
            if (range.descending) {
                if (range.step_size == 1) {
                    try writer.print("{d}.down_to({d})", .{ range.first, range.last });
                } else {
                    try writer.print("{d}.down_to({d}).step({d})", .{ range.first, range.last, range.step_size });
                }
                return;
            }
            if (range.step_size == 1) {
                try writer.print("{d}..{d}", .{ range.first, range.last });
            } else {
                try writer.print("{d}..{d}.step({d})", .{ range.first, range.last, range.step_size });
            }
        },
        .list => |list| {
            try writer.writeAll("[");
            for (list.items.items, 0..) |item, position| {
                if (position != 0) try writer.writeAll(", ");
                try item.writeThrough(writer, true, textual);
            }
            try writer.writeAll("]");
        },
        // A tuple writes the way it is written in source, and its elements are
        // quoted for the same reason a list's are.
        .tuple => |tuple| {
            try writer.writeAll("(");
            for (tuple.items, 0..) |item, position| {
                if (position != 0) try writer.writeAll(", ");
                try item.writeThrough(writer, true, textual);
            }
            try writer.writeAll(")");
        },
        // Section 8.4 prints in insertion order. A set writes the braces of its
        // type rather than the brackets its literal was written with, and an
        // empty dictionary writes `[:]`, so neither can be read as a list.
        .map => |map| {
            if (map.is_set) {
                try writer.writeAll("{");
                for (map.entries.items, 0..) |entry, position| {
                    if (position != 0) try writer.writeAll(", ");
                    try entry.key.writeThrough(writer, true, textual);
                }
                return writer.writeAll("}");
            }
            if (map.entries.items.len == 0) return writer.writeAll("[:]");
            try writer.writeAll("[");
            for (map.entries.items, 0..) |entry, position| {
                if (position != 0) try writer.writeAll(", ");
                try entry.key.writeThrough(writer, true, textual);
                try writer.writeAll(": ");
                try entry.value.writeThrough(writer, true, textual);
            }
            try writer.writeAll("]");
        },
        .closure => |closure| switch (closure.function) {
            // A nested function's key carries where it is written after `@`.
            .named => |name| try writer.print("<func {s}>", .{name[0 .. std.mem.indexOfScalar(u8, name, '@') orelse name.len]}),
            // The method's own name, as a stack trace shows it.
            .method => |key| try writer.print("<func {s}>", .{key[(std.mem.lastIndexOf(u8, key, "::") orelse 0) + 2 ..]}),
            .lambda => try writer.writeAll("<lambda>"),
        },
        .struct_value => |instance| {
            // Objects can refer to each other, and to themselves, so one that is
            // already being written shows as `Name(...)` there instead of
            // going round forever.
            if (instance.descriptor.class) {
                const already = for (displaying[0..displaying_count]) |open| {
                    if (open == instance) break true;
                } else false;
                if (already or displaying_count == displaying.len) {
                    return writer.print("{s}(...)", .{instance.descriptor.display_name});
                }
                displaying[displaying_count] = instance;
                displaying_count += 1;
            }
            defer if (instance.descriptor.class) {
                displaying_count -= 1;
            };
            // Section 15.1: a type that adopts `Textual` renders through its
            // own `to_string()`. It sits inside the cycle guard above, so an
            // object that reaches itself still shows `Name(...)` rather than
            // running forever. An enum adopting the trait uses it too, which
            // is section 12's "unless a method provides another
            // representation."
            if (@TypeOf(textual) != void) {
                if (try textual.writeTextual(self, writer)) return;
            }
            // Section 15.1: an enum value shows its qualified name.
            if (instance.descriptor.values.len > 0) {
                return writer.print("{s}.{s}", .{ instance.descriptor.display_name, instance.descriptor.values[instance.variant] });
            }
            try writer.print("{s}(", .{instance.descriptor.display_name});
            for (instance.fields, instance.descriptor.fields, 0..) |value, field, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("{s}: ", .{field.name});
                try value.writeThrough(writer, true, textual);
            }
            try writer.writeAll(")");
        },
    }
}

/// The hash a dictionary or set stores this value under.
///
/// It must agree with `equals`: two values that are equal must hash the same.
/// For a string that means hashing its normalized form, because section 9.2
/// compares strings after normalizing. The quick check answers "already
/// normalized" for almost every string, and only the rest are converted, so the
/// common case allocates nothing.
///
/// Section 8.4 makes the hash itself a runtime detail: nothing observable may
/// depend on it, and the order a program sees comes from insertion order.
///
/// `hashable` resolves section 8.4's `Hashable` the same way `equatable`
/// resolves `Equatable` in `equals` above: `{}` for the default structural
/// hash, or a context whose `customHash` runs a type adopting the trait
/// through its own `hash()`, answering `null` when it does not adopt it.
/// `Hashable` requires `Equatable` (11.2), so whatever hashes through here
/// also compares through `equatable` above — the checker's own key-eligibility
/// rule (`Type.eligibleKey`) is what keeps the two from disagreeing, by
/// refusing a type that adopts one without the other as a key at all.
pub fn hash(gpa: std.mem.Allocator, value: Value, hashable: anytype) DispatchedError!u64 {
    var hasher = std.hash.Wyhash.init(0);
    try hashInto(gpa, value, &hasher, hashable);
    return hasher.final();
}

/// A tag per kind, mixed in so that a tuple of two values cannot collide with
/// something else built from the same parts. `Int` and `Float` share one,
/// because `1 == 1.0` and equal values must hash alike.
const HashTag = enum(u8) { nothing, bool, number, string, range, tuple, struct_value, unhashable };

fn hashInto(gpa: std.mem.Allocator, value: Value, hasher: *std.hash.Wyhash, hashable: anytype) DispatchedError!void {
    const tag: HashTag = switch (value.data) {
        .nothing => .nothing,
        .bool => .bool,
        .int, .float => .number,
        .string => .string,
        .range => .range,
        .tuple => .tuple,
        .struct_value => .struct_value,
        .list, .map, .closure => .unhashable,
    };
    hasher.update(&.{@intFromEnum(tag)});

    switch (value.data) {
        .nothing => {},
        .bool => |flag| hasher.update(&.{@intFromBool(flag)}),
        .int => |number| hasher.update(std.mem.asBytes(&number)),
        .float => |number| {
            // A whole `Float` hashes as the `Int` it equals, because `==` says
            // they are equal. Negative zero equals zero, so it hashes as zero.
            if (asWholeNumber(number)) |whole| {
                hasher.update(std.mem.asBytes(&whole));
            } else {
                hasher.update(std.mem.asBytes(&number));
            }
        },
        .string => |text| {
            if (unicode.quickCheck(text.bytes) == .yes) {
                hasher.update(text.bytes);
            } else {
                const normalized = try unicode.normalize(gpa, text.bytes);
                defer gpa.free(normalized);
                hasher.update(normalized);
            }
        },
        .range => |range| {
            hasher.update(std.mem.asBytes(&range.first));
            hasher.update(std.mem.asBytes(&range.last));
            hasher.update(std.mem.asBytes(&range.step_size));
            hasher.update(&.{@intFromBool(range.descending)});
            hasher.update(&.{@intFromBool(range.is_empty)});
        },
        .tuple => |tuple| for (tuple.items) |item| try hashInto(gpa, item, hasher, hashable),
        .struct_value => |instance| {
            if (@TypeOf(hashable) != void) {
                if (try hashable.customHash(value)) |custom| {
                    hasher.update(std.mem.asBytes(&custom));
                    return;
                }
            }
            hasher.update(instance.descriptor.name);
            hasher.update(std.mem.asBytes(&instance.variant));
            for (instance.fields) |field| try hashInto(gpa, field, hasher, hashable);
        },
        // The checker rejects these as keys (8.3), so this is a safety net.
        .list, .map, .closure => {},
    }
}

/// The whole number a `Float` exactly equals, or null. `Int` and `Float` compare
/// across types, so the two must hash alike wherever they can be equal.
fn asWholeNumber(number: f64) ?i64 {
    if (std.math.isNan(number) or std.math.isInf(number)) return null;
    if (@floor(number) != number) return null;
    if (number < -9223372036854775808.0 or number >= 9223372036854775808.0) return null;
    return @intFromFloat(number);
}

/// A string as a double-quoted literal would write it, with section 5.1's
/// escapes where they are needed.
fn writeQuoted(bytes: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("\"");
    for (bytes) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        0 => try writer.writeAll("\\0"),
        else => try writer.writeByte(c),
    };
    try writer.writeAll("\"");
}

/// What running a value's own `equals()`/`hash()` can raise, the same small,
/// stable vocabulary `Interpreter.Error` names for any nested call: `Raised`
/// (the method itself raised, or something it calls did), the four other
/// non-local control-flow tags a method body could in principle unwind
/// through, and ordinary allocation/write failure. Declared independently
/// here rather than imported from `Interpreter.zig`, to keep this file free
/// of that dependency — Zig unifies error tags by name rather than by which
/// file declared them, so this coerces to and from `Interpreter.Error`
/// without either file needing to import the other. It also breaks the
/// mutual inferred-error-set cycle `equals` and `Heap.lookupIn` would
/// otherwise form by calling each other: one side of a cycle like that needs
/// an explicit return type, and this is it.
pub const DispatchedError = error{ Raised, Returned, Broke, Continued, Exited, StepLimit } ||
    std.mem.Allocator.Error || std.Io.Writer.Error;

/// Emerald's `==`. Numbers compare by mathematical value, as `order` does, so
/// a NaN equals nothing, itself included. Strings are equal when they are
/// canonically equivalent (9.2), which can need normalizing, hence the
/// allocator. Lists are equal when they hold equal elements in the same order
/// (8.4), using this same `==` for each. Two functions are equal when they are
/// the same function: there is no way to compare what code does. Values of
/// different kinds are never equal; the checker rejects comparing them, so that
/// answer is a safety net.
///
/// `equatable` resolves section 8.4's `Equatable`: either `{}`, which compares
/// every struct or class through the default (structural for a struct, identity
/// for a class), or a context with a `customEquals` method that runs a type
/// adopting the trait through its own `equals()` and answers `null` when the
/// type does not adopt it, so the default still applies. Threaded through
/// every recursive comparison (list elements, dictionary values, struct
/// fields) so an adopting type compares the same nested inside a collection
/// as it does alone — the same shape `writeThrough`'s `textual` context uses
/// for `Textual`.
pub fn equals(gpa: std.mem.Allocator, left: Value, right: Value, equatable: anytype) DispatchedError!bool {
    return switch (left.data) {
        .nothing => right.data == .nothing,
        .bool => |a| switch (right.data) {
            .bool => |b| a == b,
            else => false,
        },
        .int, .float => order(left, right) == .eq,
        .string => |a| switch (right.data) {
            .string => |b| unicode.equal(gpa, a.bytes, b.bytes),
            else => false,
        },
        .range => |a| switch (right.data) {
            .range => |b| a.first == b.first and a.last == b.last and a.step_size == b.step_size and a.descending == b.descending and a.is_empty == b.is_empty,
            else => false,
        },
        .closure => |a| switch (right.data) {
            .closure => |b| sameFunction(a, b),
            else => false,
        },
        .list => |a| switch (right.data) {
            .list => |b| equalsSequence(gpa, a.items.items, b.items.items, equatable),
            else => false,
        },
        // Section 8.4: a set compares by membership and a dictionary by its
        // keys and values, neither by insertion order.
        .map => |a| switch (right.data) {
            .map => |b| blk: {
                if (a.entries.items.len != b.entries.items.len) break :blk false;
                for (a.entries.items) |entry| {
                    const found = try Heap.lookupIn(gpa, b, entry.hash, entry.key, equatable) orelse break :blk false;
                    if (a.is_set) continue;
                    if (!try equals(gpa, entry.value, found.value, equatable)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        // Section 8.4: tuples compare their values position by position. The
        // checker has already proved the arities match.
        .tuple => |a| switch (right.data) {
            .tuple => |b| equalsSequence(gpa, a.items, b.items, equatable),
            else => false,
        },
        .struct_value => |a| switch (right.data) {
            .struct_value => |b| blk: {
                if (a.descriptor != b.descriptor) break :blk false;
                if (@TypeOf(equatable) != void) {
                    if (try equatable.customEquals(left, right)) |result| break :blk result;
                }
                // Section 10.1: classes compare by identity.
                if (a.descriptor.class) break :blk a == b;
                if (a.variant != b.variant) break :blk false;
                break :blk try equalsSequence(gpa, a.fields, b.fields, equatable);
            },
            else => false,
        },
    };
}

/// Equality for the ordered value storage shared by lists, tuples, and value
/// structs. Their outer identities have already been checked by their caller.
fn equalsSequence(gpa: std.mem.Allocator, left: []const Value, right: []const Value, equatable: anytype) DispatchedError!bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!try equals(gpa, a, b, equatable)) return false;
    }
    return true;
}

/// Whether two callable values are the same function.
///
/// Capturing a top-level function twice gives the same function both times, so
/// the two captures are equal even though each capture is its own object. Two
/// lambdas, nested functions, or captured methods are equal only when they are
/// the same closure: two evaluations of the same lambda capture different
/// variables and are genuinely different functions.
fn sameFunction(left: *Heap.Closure, right: *Heap.Closure) bool {
    if (left == right) return true;
    if (left.function != .named or right.function != .named) return false;
    // A nested function (7.1) captured the scopes of one call, so like a
    // lambda it is the same function only as the same closure.
    if (left.captured.len > 0 or right.captured.len > 0) return false;
    return std.mem.eql(u8, left.function.named, right.function.named);
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
            .nothing, .bool, .string, .range, .list, .tuple, .map, .closure, .struct_value => null,
        },
        .float => |a| switch (right.data) {
            .int => |b| if (orderIntFloat(b, a)) |result| result.invert() else null,
            .float => |b| if (std.math.isNan(a) or std.math.isNan(b))
                null
            else
                std.math.order(a, b),
            .nothing, .bool, .string, .range, .list, .tuple, .map, .closure, .struct_value => null,
        },
        .nothing, .bool, .string, .range, .list, .tuple, .map, .closure, .struct_value => null,
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

test "a hash agrees with equality for numbers" {
    const gpa = testing.allocator;
    // `1 == 1.0`, so the two must hash alike or a dictionary could hold both.
    try testing.expectEqual(try hash(gpa, .initInt(1), {}), try hash(gpa, .initFloat(1.0), {}));
    try testing.expectEqual(try hash(gpa, .initFloat(-0.0), {}), try hash(gpa, .initFloat(0.0), {}));
    try testing.expectEqual(try hash(gpa, .initInt(0), {}), try hash(gpa, .initFloat(-0.0), {}));
    try testing.expect(try hash(gpa, .initInt(1), {}) != try hash(gpa, .initInt(2), {}));
    // A fraction is not a whole number, so it hashes as itself.
    try testing.expect(try hash(gpa, .initFloat(1.5), {}) != try hash(gpa, .initInt(1), {}));
    // A value out of `Int`'s range stays a `Float`, and must not be truncated.
    try testing.expect(try hash(gpa, .initFloat(1e300), {}) != try hash(gpa, .initInt(0), {}));
}

test "a hash distinguishes values of different types" {
    const gpa = testing.allocator;
    try testing.expect(try hash(gpa, .initBool(false), {}) != try hash(gpa, .initInt(0), {}));
    try testing.expect(try hash(gpa, .initBool(true), {}) != try hash(gpa, .initInt(1), {}));
    try testing.expect(try hash(gpa, nothing, {}) != try hash(gpa, .initInt(0), {}));
}

test "a hash agrees with equality for strings, which normalize first" {
    const gpa = testing.allocator;
    var heap: Heap = .init(gpa);
    defer heap.deinit();

    // The same text composed, and as `e` plus a combining acute accent.
    const composed = try heap.copyText("café");
    const decomposed = try heap.copyText("cafe\u{301}");
    try testing.expect(try equals(gpa, composed, decomposed, {}));
    try testing.expectEqual(try hash(gpa, composed, {}), try hash(gpa, decomposed, {}));

    const other = try heap.copyText("cafe");
    try testing.expect(try hash(gpa, composed, {}) != try hash(gpa, other, {}));
}
