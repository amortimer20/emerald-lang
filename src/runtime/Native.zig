//! What a native needs to run, whichever engine calls it
//! (docs/compiler-design-plan.md, decision 4 and slice 1b).
//!
//! A native takes evaluated values and gives a value. It never sees syntax, so
//! the interpreter evaluates the arguments first, and a compiled program will
//! pass its own. When a native fails it records a `Failure` (the error type,
//! the message and the help) and returns `error.Raised`; the engine attaches
//! the location, since only the engine knows where the call was. So the text a
//! beginner reads is written once, here, and both engines show it.
//!
//! A native that needs the program's own code, such as a struct's `equals()`,
//! `hash()` or `compare()`, or a source of randomness the engine owns, asks
//! through `Engine`, a small table of callbacks the engine supplies.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Regex = @import("Regex.zig");
const TimeZone = @import("TimeZone.zig");

/// The errors a native can return: its own `Raised`, allocation failure, and
/// whatever a callback into the program's code can unwind with.
pub const Error = Value.DispatchedError;

/// A failure a native reports. `type_name` is the prelude error type, empty
/// for `RuntimeError`.
pub const Failure = struct {
    type_name: []const u8 = "",
    message: []const u8,
    help: []const u8,
};

/// Callbacks into the engine running the program.
pub const Engine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `left.equals(right)` when `left`'s type adopts `Equatable`, else null.
        custom_equals: *const fn (ptr: *anyopaque, left: Value, right: Value) Error!?bool,
        /// `value.hash()` when its type adopts `Hashable`, else null.
        custom_hash: *const fn (ptr: *anyopaque, value: Value) Error!?u64,
        /// `left.compare(right)` for a type that adopts `Ordered`.
        compare: *const fn (ptr: *anyopaque, left: Value, right: Value) Error!Value,
        /// The program's unseeded source of randomness.
        random: *const fn (ptr: *anyopaque) std.Random,
        /// The descriptor of the prelude's struct `name`, such as `Regex::Match`.
        prelude_struct: *const fn (ptr: *anyopaque, name: []const u8) *const Value.StructType,
    };
};

/// What natives keep between calls for one running program, which the engine
/// owns. Its contents live in the context's `arena`.
pub const State = struct {
    /// Section 15.4's compiled patterns, keyed by options and pattern, so a
    /// `Regex` built again, as in a loop, is compiled once. Past
    /// `regex_cache_limit` patterns, each is compiled for one call instead.
    regex_cache: std.StringHashMapUnmanaged(Regex.Program) = .empty,
    /// The machine's zone, as the engine found it when the program started.
    local_zone: TimeZone.Local = .utc,
    /// Section 15.8's database, loaded the first time a program names a zone,
    /// and the zones read from it so far.
    zone_database: ?TimeZone.Database = null,
    zone_cache: std.StringHashMapUnmanaged(TimeZone.Rules) = .empty,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    /// For failure text and `state`, which live until the program ends.
    arena: std.mem.Allocator,
    heap: *Heap,
    io: std.Io,
    state: *State,
    engine: Engine,
    failure: ?Failure = null,

    pub fn raise(ctx: *Context, message: []const u8, help: []const u8) Error {
        ctx.failure = .{ .message = message, .help = help };
        return error.Raised;
    }

    pub fn raiseFmt(ctx: *Context, comptime message_format: []const u8, message_args: anytype, help: []const u8) Error {
        return ctx.raise(try std.fmt.allocPrint(ctx.arena, message_format, message_args), help);
    }

    pub fn raiseTyped(ctx: *Context, type_name: []const u8, message: []const u8, help: []const u8) Error {
        ctx.failure = .{ .type_name = type_name, .message = message, .help = help };
        return error.Raised;
    }

    /// The `equatable` argument `Value.equals` and `Value.hash` take, which
    /// runs a type's own `equals()` and `hash()` through the engine.
    pub fn equatable(ctx: *Context) Equatable {
        return .{ .engine = ctx.engine };
    }

    pub fn random(ctx: *Context) std.Random {
        return ctx.engine.vtable.random(ctx.engine.ptr);
    }

    pub fn preludeStruct(ctx: *Context, name: []const u8) *const Value.StructType {
        return ctx.engine.vtable.prelude_struct(ctx.engine.ptr, name);
    }

    pub fn compare(ctx: *Context, left: Value, right: Value) Error!Value {
        return ctx.engine.vtable.compare(ctx.engine.ptr, left, right);
    }

    /// A new string that takes `bytes`, which the caller allocated with `gpa`.
    pub fn ownedText(ctx: *Context, bytes: []u8) Error!Value {
        return .{ .data = .{ .string = try ctx.heap.createText(bytes) } };
    }
};

pub const Equatable = struct {
    engine: Engine,

    pub fn customEquals(self: Equatable, left: Value, right: Value) Error!?bool {
        return self.engine.vtable.custom_equals(self.engine.ptr, left, right);
    }

    pub fn customHash(self: Equatable, value: Value) Error!?u64 {
        return self.engine.vtable.custom_hash(self.engine.ptr, value);
    }
};

/// The help for every failure an `Int` result too large or too small causes.
pub const integer_range_help =
    "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807.";

/// Section 4.4's widening, the only implicit conversion: an `Int` where a
/// `Float` is expected becomes one.
pub fn widen(value: Value, kind: Value.Kind) Value {
    if (kind != .float) return value;
    return switch (value.data) {
        .int => |number| .initFloat(@floatFromInt(number)),
        else => value,
    };
}

/// Whether a value is or holds a NaN, which can never be found again as a key.
pub fn holdsNan(value: Value) bool {
    return switch (value.data) {
        .float => |number| std.math.isNan(number),
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (holdsNan(item)) break :blk true;
            }
            break :blk false;
        },
        .struct_value => |instance| blk: {
            for (instance.fields) |field| {
                if (holdsNan(field)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// A number as a `Float`. Callers check that it is a number first.
pub fn toFloat(value: Value) f64 {
    return switch (value.data) {
        .int => |number| @floatFromInt(number),
        .float => |number| number,
        .range => unreachable,
        .nothing, .bool, .string, .bytes, .list, .tuple, .map, .closure, .struct_value => unreachable,
    };
}
