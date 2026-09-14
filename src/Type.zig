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
    /// Section 8.2's `(String, Int)`. `elements` holds the positions, of which
    /// there are always at least two.
    tuple,
    /// Section 8.2's `[String: Int]`. `key` holds the key type and `element`
    /// the value type.
    dictionary,
    /// Section 8.2's `{String}`. `element` holds the member type.
    set,
    /// Section 7.1's `func(Int): String`. `signature` holds its shape.
    function,
    /// Section 10.1's user-defined value type. `user` carries stable identity
    /// and its checked fields.
    struct_value,
    /// A type that could not be determined because something was already
    /// reported. It is compatible with everything, so one mistake produces one
    /// diagnostic instead of a cascade through every expression containing it.
    invalid,
};

kind: Kind,
/// The element type of a list, and null for every other kind.
element: ?*const Type = null,
/// The position types of a tuple, and empty for every other kind.
elements: []const Type = &.{},
/// The key type of a dictionary, and null for every other kind.
key: ?*const Type = null,
/// What a function takes and gives, and null for every other kind.
signature: ?*const Signature = null,
/// Stable metadata for a user-defined type; null for built-ins.
user: ?*const User = null,
/// Section 4.2's trailing `?`: this value may be absent.
///
/// A flag rather than a wrapping kind, because section 4.5 settles that
/// optionals never nest. There is nothing for a second layer to mean, so there
/// is no way to build one by accident, and `Int?` stays as cheap to carry
/// around as `Int`. Placement is still structural: this flag on a list is
/// `[String]?`, while the same flag on its element is `[String?]`.
optional: bool = false,
/// Section 11.4's `Self` written in a trait: a value of whichever type adopts
/// `user`, the trait, known only through its contract. Unlike a value seen
/// through the trait, a second `Self` is known to be of the same type, so a
/// member that takes `Self` can be given one.
opaque_self: bool = false,

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

/// Shared by every occurrence of one user-defined type. The checker allocates
/// this before resolving fields so declarations may refer to one another.
pub const User = struct {
    name: []const u8,
    display_name: []const u8,
    /// Section 10.1: a class's values are shared references rather than
    /// copied values.
    class: bool = false,
    /// Section 11.1: a trait, whose values are values of the types adopting
    /// it, seen only through its contract.
    trait: bool = false,
    /// Section 12: an enum, whose only values are the ones it lists.
    enumeration: bool = false,
    /// Section 10.7's base class, for a class that extends one.
    base: ?*const User = null,
    /// Section 11.2's `with` list: the traits adopted, or that a trait builds
    /// on.
    traits: []const *const User = &.{},
    /// Every stored field, a base class's first, in declaration order.
    fields: []const Field = &.{},
    /// How many of `fields` come from base classes.
    inherited: usize = 0,

    pub const Field = struct {
        name: []const u8,
        type: Type,
        mutable: bool,
        /// The key of the type that declares it, which section 10.5's
        /// privacy is judged against.
        owner: []const u8 = "",
    };

    /// Whether this is `other` or extends it, directly or through its base
    /// classes (10.7).
    pub fn extends(self: *const User, other: *const User) bool {
        var at: ?*const User = self;
        while (at) |current| : (at = current.base) {
            if (current == other) return true;
        }
        return false;
    }

    /// Whether a value of this type is also one of `other`: it extends it, or
    /// `other` is a trait that it, a class it extends, or a trait any of them
    /// builds on adopts (11.2).
    pub fn conformsTo(self: *const User, other: *const User) bool {
        if (self.extends(other)) return true;
        if (!other.trait) return false;
        var at: ?*const User = self;
        while (at) |current| : (at = current.base) {
            for (current.traits) |adopted| {
                if (adopted.conformsTo(other)) return true;
            }
        }
        return false;
    }
};

pub const Signatures = std.StringHashMapUnmanaged(Signature);

pub const nothing: Type = .{ .kind = .nothing };
pub const @"bool": Type = .{ .kind = .bool };
pub const int: Type = .{ .kind = .int };
pub const float: Type = .{ .kind = .float };
pub const string: Type = .{ .kind = .string };
pub const invalid: Type = .{ .kind = .invalid };

pub fn structOf(user: *const User) Type {
    return .{ .kind = .struct_value, .user = user };
}

/// `Self` inside the trait `trait`.
pub fn selfOf(trait: *const User) Type {
    return .{ .kind = .struct_value, .user = trait, .opaque_self = true };
}

/// Whether `Self` appears anywhere in the type.
pub fn mentionsSelf(self: Type) bool {
    return switch (self.kind) {
        .struct_value => self.opaque_self,
        .list, .set => self.element.?.mentionsSelf(),
        .dictionary => self.key.?.mentionsSelf() or self.element.?.mentionsSelf(),
        .tuple => for (self.elements) |element| {
            if (element.mentionsSelf()) break true;
        } else false,
        .function => blk: {
            const signature = self.signature.?;
            for (signature.parameters) |parameter| {
                if (parameter.mentionsSelf()) break :blk true;
            }
            break :blk signature.return_type.mentionsSelf();
        },
        .nothing, .bool, .int, .float, .string, .invalid => false,
    };
}

/// `[element]`, with the element allocated from `allocator`, which must outlive
/// the result.
pub fn listOf(allocator: std.mem.Allocator, element: Type) std.mem.Allocator.Error!Type {
    const stored = try allocator.create(Type);
    stored.* = element;
    return .{ .kind = .list, .element = stored };
}

/// `[key: value]`, with both allocated from `allocator`, which must outlive the
/// result.
pub fn dictionaryOf(allocator: std.mem.Allocator, key_type: Type, value: Type) std.mem.Allocator.Error!Type {
    const stored_key = try allocator.create(Type);
    stored_key.* = key_type;
    const stored_value = try allocator.create(Type);
    stored_value.* = value;
    return .{ .kind = .dictionary, .key = stored_key, .element = stored_value };
}

/// `{element}`, with the element allocated from `allocator`, which must outlive
/// the result.
pub fn setOf(allocator: std.mem.Allocator, element: Type) std.mem.Allocator.Error!Type {
    const stored = try allocator.create(Type);
    stored.* = element;
    return .{ .kind = .set, .element = stored };
}

/// Section 8.3: a dictionary key needs stable equality and hashing. Built-in
/// scalars, strings, and tuples whose positions recursively qualify. A list can
/// change after it is stored, and an absent key is not a key at all, so neither
/// qualifies. Enums and structs join this when they exist.
pub fn eligibleKey(self: Type) bool {
    var seen: [256]*const User = undefined;
    return self.eligibleKeyInner(&seen, 0);
}

fn eligibleKeyInner(self: Type, seen: *[256]*const User, depth: usize) bool {
    if (self.optional) return false;
    return switch (self.kind) {
        .bool, .int, .float, .string => true,
        .tuple => blk: {
            for (self.elements) |element| {
                if (!element.eligibleKeyInner(seen, depth)) break :blk false;
            }
            break :blk true;
        },
        // Reported already, and treated as usable so one mistake reports once.
        .invalid => true,
        .struct_value => blk: {
            const user = self.user.?;
            // Section 8.3: an object can change while it is a key, so
            // classes are not initial dictionary keys, and a trait's value
            // may be an object.
            if (user.class or user.trait) break :blk false;
            for (seen[0..depth]) |earlier| {
                if (earlier == user) break :blk false;
            }
            if (depth == seen.len) break :blk false;
            seen[depth] = user;
            for (user.fields) |field| {
                if (!field.type.eligibleKeyInner(seen, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .nothing, .list, .dictionary, .set, .function => false,
    };
}

/// `(A, B)`, with the positions allocated from `allocator`, which must outlive
/// the result. Section 8.2 requires at least two.
pub fn tupleOf(allocator: std.mem.Allocator, elements: []const Type) std.mem.Allocator.Error!Type {
    std.debug.assert(elements.len >= 2);
    return .{ .kind = .tuple, .elements = try allocator.dupe(Type, elements) };
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
        .dictionary => try writer.print("[{f}: {f}]", .{ self.key.?.*, self.element.?.* }),
        .set => try writer.print("{{{f}}}", .{self.element.?.*}),
        .tuple => {
            try writer.writeAll("(");
            for (self.elements, 0..) |element, position| {
                if (position != 0) try writer.writeAll(", ");
                try writer.print("{f}", .{element});
            }
            try writer.writeAll(")");
        },
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
        .struct_value => try writer.writeAll(if (self.opaque_self) "Self" else self.user.?.display_name),
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
        .nothing, .bool, .string, .list, .tuple, .dictionary, .set, .function, .struct_value, .invalid => false,
    };
}

/// Whether the type is, or contains, one that could not be determined.
pub fn isInvalid(self: Type) bool {
    return switch (self.kind) {
        .invalid => true,
        .list, .set => self.element.?.isInvalid(),
        .dictionary => self.key.?.isInvalid() or self.element.?.isInvalid(),
        .tuple => blk: {
            for (self.elements) |element| {
                if (element.isInvalid()) break :blk true;
            }
            break :blk false;
        },
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
    if (self.kind == .struct_value) return self.user.? == other.user.? and self.opaque_self == other.opaque_self;
    if (self.kind == .list or self.kind == .set) return self.element.?.same(other.element.?.*);
    if (self.kind == .dictionary) {
        return self.key.?.same(other.key.?.*) and self.element.?.same(other.element.?.*);
    }
    if (self.kind == .tuple) {
        if (self.elements.len != other.elements.len) return false;
        for (self.elements, other.elements) |a, b| {
            if (!a.same(b)) return false;
        }
        return true;
    }
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

    // Section 10.7: an object of a subclass is also one of its base class,
    // and it is shared rather than converted, so nothing changes at runtime.
    if (self.kind == .struct_value and target.kind == .struct_value) {
        // Section 11.4: nothing but `Self` is known to be `Self`, while `Self`
        // is a value of its trait and of everything the trait builds on.
        if (target.opaque_self) return self.opaque_self and self.user.? == target.user.?;
        return self.user.?.conformsTo(target.user.?);
    }

    // A tuple widens position by position, unlike a list. Section 8.2 gives no
    // way to assign to a position, so a `(Int, Int)` used as a `(Float, Int)`
    // can never be written through and observed as the wrong type — which is
    // exactly the argument that makes a list invariant.
    if (self.kind == .tuple and target.kind == .tuple and !target.optional) {
        if (self.elements.len != target.elements.len) return false;
        for (self.elements, target.elements) |mine, theirs| {
            if (!mine.assignableTo(theirs)) return false;
        }
        return true;
    }

    return self.same(target);
}

/// Section 8.5's essential vocabulary for a dictionary and a set. They share
/// `empty?` with a list; the rest answer to their own names.
pub const map_methods = std.StaticStringMap(void).initComptime(.{
    .{"empty?"},
    .{"contains?"},
    .{"contains_key?"},
    .{"contains_value?"},
    .{"keys"},
    .{"values"},
    .{"entries"},
    .{"add"},
    .{"remove"},
    .{"merge"},
});

/// Those of them that change what they are called on.
pub const map_mutators = std.StaticStringMap(void).initComptime(.{
    .{"add"},
    .{"remove"},
    .{"merge"},
});

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
    pub const Result = enum { bool, int, float, string, strings, string_parts };
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
    .{ "insert_at", StringMethod{ .parameters = &.{ .int, .string }, .result = .string } },
    .{ "substring", StringMethod{ .parameters = &.{ .int, .int }, .optional = 1, .result = .string } },
    .{ "remove_prefix", StringMethod{ .parameters = &.{.string}, .result = .string } },
    .{ "remove_suffix", StringMethod{ .parameters = &.{.string}, .result = .string } },
    .{ "collapse_repeats", StringMethod{ .parameters = &.{}, .result = .string } },
    .{ "pad_start", StringMethod{ .parameters = &.{ .int, .string }, .optional = 1, .result = .string } },
    .{ "pad_end", StringMethod{ .parameters = &.{ .int, .string }, .optional = 1, .result = .string } },
    .{ "pad_center", StringMethod{ .parameters = &.{ .int, .string }, .optional = 1, .result = .string } },
    .{ "split", StringMethod{ .parameters = &.{.string}, .result = .strings } },
    .{ "lines", StringMethod{ .parameters = &.{}, .result = .strings } },
    .{ "chars", StringMethod{ .parameters = &.{}, .result = .strings } },
    .{ "partition", StringMethod{ .parameters = &.{.string}, .result = .string_parts } },
    .{ "index_of", StringMethod{ .parameters = &.{.string}, .result = .int, .maybe = true } },
    .{ "to_int", StringMethod{ .parameters = &.{}, .result = .int } },
    .{ "to_int_maybe", StringMethod{ .parameters = &.{}, .result = .int, .maybe = true } },
    .{ "to_float_maybe", StringMethod{ .parameters = &.{}, .result = .float, .maybe = true } },
    .{ "to_int_or", StringMethod{ .parameters = &.{.int}, .result = .int } },
    .{ "to_float", StringMethod{ .parameters = &.{}, .result = .float } },
    .{ "to_float_or", StringMethod{ .parameters = &.{.float}, .result = .float } },
});

/// Section 9.3's methods on an `Int`. Every argument in this first numeric
/// vocabulary is another `Int`; keeping the result here gives the checker one
/// authoritative description of the callable surface.
pub const IntMethod = struct {
    parameters: usize,
    result: Result,

    pub const Result = enum { bool, int, float, ints, string };
};

pub const int_methods = std.StaticStringMap(IntMethod).initComptime(.{
    .{ "abs", IntMethod{ .parameters = 0, .result = .int } },
    .{ "clamp", IntMethod{ .parameters = 2, .result = .int } },
    .{ "between?", IntMethod{ .parameters = 2, .result = .bool } },
    .{ "zero?", IntMethod{ .parameters = 0, .result = .bool } },
    .{ "positive?", IntMethod{ .parameters = 0, .result = .bool } },
    .{ "negative?", IntMethod{ .parameters = 0, .result = .bool } },
    .{ "even?", IntMethod{ .parameters = 0, .result = .bool } },
    .{ "odd?", IntMethod{ .parameters = 0, .result = .bool } },
    .{ "multiple_of?", IntMethod{ .parameters = 1, .result = .bool } },
    .{ "digits", IntMethod{ .parameters = 0, .result = .ints } },
    .{ "gcd", IntMethod{ .parameters = 1, .result = .int } },
    .{ "lcm", IntMethod{ .parameters = 1, .result = .int } },
    .{ "factorial", IntMethod{ .parameters = 0, .result = .int } },
    .{ "to_float", IntMethod{ .parameters = 0, .result = .float } },
    .{ "to_string", IntMethod{ .parameters = 0, .result = .string } },
});

/// Section 9.3's methods on a `Float`. An `Int` is accepted for a `.float`
/// operand through Emerald's ordinary widening rule; `round_to` takes an
/// integer count of decimal places.
pub const FloatMethod = struct {
    parameters: []const Operand,
    result: Result,

    pub const Operand = enum { float, int };
    pub const Result = enum { bool, int, float, string };
};

pub const float_methods = std.StaticStringMap(FloatMethod).initComptime(.{
    .{ "abs", FloatMethod{ .parameters = &.{}, .result = .float } },
    .{ "clamp", FloatMethod{ .parameters = &.{ .float, .float }, .result = .float } },
    .{ "between?", FloatMethod{ .parameters = &.{ .float, .float }, .result = .bool } },
    .{ "zero?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "positive?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "negative?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "floor", FloatMethod{ .parameters = &.{}, .result = .int } },
    .{ "ceil", FloatMethod{ .parameters = &.{}, .result = .int } },
    .{ "round", FloatMethod{ .parameters = &.{}, .result = .int } },
    .{ "round_to", FloatMethod{ .parameters = &.{.int}, .result = .float } },
    .{ "truncate", FloatMethod{ .parameters = &.{}, .result = .int } },
    .{ "finite?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "infinite?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "nan?", FloatMethod{ .parameters = &.{}, .result = .bool } },
    .{ "to_int", FloatMethod{ .parameters = &.{}, .result = .int } },
    .{ "to_string", FloatMethod{ .parameters = &.{}, .result = .string } },
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

test "an object of a subclass is assignable to its base class but not the reverse" {
    var animal: User = .{ .name = "Animal", .display_name = "Animal", .class = true };
    var dog: User = .{ .name = "Dog", .display_name = "Dog", .class = true, .base = &animal };
    const puppy: User = .{ .name = "Puppy", .display_name = "Puppy", .class = true, .base = &dog };
    const other: User = .{ .name = "Other", .display_name = "Other", .class = true };
    try testing.expect(structOf(&puppy).assignableTo(structOf(&animal)));
    try testing.expect(structOf(&dog).assignableTo(structOf(&animal).optionalOf()));
    try testing.expect(!structOf(&animal).assignableTo(structOf(&dog)));
    try testing.expect(!structOf(&other).assignableTo(structOf(&animal)));
    // Lists stay invariant (4.4).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dogs = try listOf(arena_state.allocator(), structOf(&dog));
    try testing.expect(!dogs.assignableTo(try listOf(arena_state.allocator(), structOf(&animal))));
}

test "Self is a value of its trait, but only Self is Self" {
    const addable: User = .{ .name = "Addable", .display_name = "Addable", .trait = true };
    const traits = [_]*const User{&addable};
    const numeric: User = .{ .name = "Numeric", .display_name = "Numeric", .trait = true, .traits = &traits };
    const vector: User = .{ .name = "Vector", .display_name = "Vector", .traits = &.{&numeric} };
    const self_type = selfOf(&numeric);
    try testing.expect(self_type.assignableTo(self_type));
    try testing.expect(self_type.assignableTo(structOf(&numeric)));
    try testing.expect(self_type.assignableTo(structOf(&addable).optionalOf()));
    try testing.expect(!structOf(&numeric).assignableTo(self_type));
    try testing.expect(!structOf(&vector).assignableTo(self_type));
    try testing.expect(!self_type.assignableTo(selfOf(&addable)));
    try testing.expect(!self_type.same(structOf(&numeric)));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const listed = try listOf(arena_state.allocator(), self_type.optionalOf());
    try testing.expect(listed.mentionsSelf());
    try testing.expectEqualStrings("[Self?]", try std.fmt.allocPrint(arena_state.allocator(), "{f}", .{listed}));
    try testing.expect(!structOf(&vector).mentionsSelf());
}
