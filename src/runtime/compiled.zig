//! The runtime as a compiled program links it (docs/compiler-design-plan.md,
//! decisions 4 and 7): a C ABI over the same runtime the interpreter calls,
//! declared for generated C in `emerald.h`, which lives beside this file.
//!
//! Generated C does the common case of each operation itself, as the
//! interpreter does, and calls in here for the rest: output, the operations
//! that fail, and the exact comparisons C cannot spell. A failure is recorded
//! here and every function on the way out returns a nonzero status, adding its
//! call to the trace (`em_trace`), until `em_finish` reports it.
//!
//! The message text comes from `Operations.zig`, so a compiled program fails
//! with the interpreter's words. The location, the quoted line and the carets
//! were rendered when the program was built, by the same code that renders the
//! interpreter's diagnostics, and arrive here as an `em_site`.
//!
//! One program runs at a time in one process, so the state here is global.
//! Tasks arrive in slice 6, which gives it a lock or a per-task home.

const std = @import("std");
const Value = @import("Value.zig");
const Heap = @import("Heap.zig");
const Native = @import("Native.zig");
const Operations = @import("Operations.zig");

/// Where a failure happened: `path:line:column`, and the quoted source line
/// with its carets, each line ending in a newline.
pub const Site = extern struct {
    location: [*:0]const u8,
    snippet: [*:0]const u8,
};

/// One call on the way out of a failure: the function called, and where.
pub const Frame = extern struct {
    function: [*:0]const u8,
    location: [*:0]const u8,
    /// Whether `function` is a name the program wrote, which is quoted, or a
    /// description such as "a block", which is not.
    named: bool,
};

const gpa = std.heap.smp_allocator;

var threaded: std.Io.Threaded = undefined;
var io: std.Io = undefined;
var arena_state: std.heap.ArenaAllocator = .init(gpa);
var heap: Heap = .init(gpa);
var state: Native.State = .{};

var out_buffer: [64 * 1024]u8 = undefined;
var out_writer: std.Io.File.Writer = undefined;

/// The failure being reported, once something has failed.
var failure: ?Recorded = null;
var trace: std.ArrayList(*const Frame) = .empty;

const Recorded = struct {
    site: *const Site,
    type_name: []const u8,
    message: []const u8,
    help: []const u8,
};

/// The engine callbacks a native may ask for. Nothing compiled so far calls a
/// native that needs one; the slices that compile structs, traits and
/// randomness supply them.
const no_engine: Native.Engine.VTable = .{
    .custom_equals = struct {
        fn f(_: *anyopaque, _: Value, _: Value) Native.Error!?bool {
            return null;
        }
    }.f,
    .custom_hash = struct {
        fn f(_: *anyopaque, _: Value) Native.Error!?u64 {
            return null;
        }
    }.f,
    .compare = struct {
        fn f(_: *anyopaque, _: Value, _: Value) Native.Error!Value {
            unreachable;
        }
    }.f,
    .random = struct {
        fn f(_: *anyopaque) std.Random {
            unreachable;
        }
    }.f,
    .prelude_struct = struct {
        fn f(_: *anyopaque, _: []const u8) *const Value.StructType {
            unreachable;
        }
    }.f,
};

var engine_token: u8 = 0;

fn context() Native.Context {
    return .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .heap = &heap,
        .io = io,
        .state = &state,
        .engine = .{ .ptr = &engine_token, .vtable = &no_engine },
    };
}

/// Runs `function(ctx, arguments...)`, recording its failure at `site`.
/// Gives 0 on success and 1 on failure, generated C's status.
fn call(site: *const Site, comptime function: anytype, arguments: anytype, result: anytype) c_int {
    var ctx = context();
    const outcome = @call(.auto, function, .{&ctx} ++ arguments);
    // A native that only explains a failure gives an error set, not a union.
    if (@typeInfo(@TypeOf(outcome)) == .error_set) {
        fail(site, &ctx, outcome);
        return 1;
    }
    if (outcome) |value| {
        if (@TypeOf(result) != void) result.* = value;
        return 0;
    } else |err| {
        fail(site, &ctx, err);
        return 1;
    }
}

fn fail(site: *const Site, ctx: *const Native.Context, err: Native.Error) void {
    switch (err) {
        error.Raised => {
            const recorded = ctx.failure.?;
            failure = .{ .site = site, .type_name = recorded.type_name, .message = recorded.message, .help = recorded.help };
        },
        error.OutOfMemory => outOfMemory(),
        else => unreachable, // only a callback into the program returns the others
    }
}

fn outOfMemory() noreturn {
    std.Io.File.stderr().writeStreamingAll(io, "Emerald ran out of memory.\n") catch {};
    std.process.exit(70);
}

export fn em_start() void {
    threaded = .init(gpa, .{});
    io = threaded.io();
    out_writer = std.Io.File.stdout().writerStreaming(io, &out_buffer);
}

/// Ends the program: flushes its output, and reports the failure when
/// `status` is not zero. Gives the process's exit status, 2 for a runtime
/// error as `emerald run` gives (section 18.1).
export fn em_finish(status: c_int) c_int {
    out_writer.interface.flush() catch {};
    if (status == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    report(&err_writer.interface) catch {};
    err_writer.interface.flush() catch {};
    return 2;
}

fn report(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const recorded = failure.?;
    try writer.print("{s}: ", .{std.mem.span(recorded.site.location)});
    if (recorded.type_name.len != 0) try writer.print("{s}: ", .{recorded.type_name});
    try writer.print("{s}\n{s}{s}\n", .{ recorded.message, std.mem.span(recorded.site.snippet), recorded.help });
    // Section 7.2: a run of the same call prints once, with a count.
    var index: usize = 0;
    while (index < trace.items.len) {
        const frame = trace.items[index];
        var repeats: usize = 1;
        while (index + repeats < trace.items.len and sameFrame(trace.items[index + repeats], frame)) repeats += 1;
        const function = std.mem.span(frame.function);
        if (frame.named) try writer.print("in `{s}`, called at ", .{function}) else try writer.print("in {s}, called at ", .{function});
        try writer.writeAll(std.mem.span(frame.location));
        if (repeats > 1) try writer.print(" ({d} times)", .{repeats});
        try writer.writeAll("\n");
        index += repeats;
    }
}

fn sameFrame(a: *const Frame, b: *const Frame) bool {
    return a == b or (std.mem.orderZ(u8, a.location, b.location) == .eq and std.mem.orderZ(u8, a.function, b.function) == .eq);
}

/// Adds a call to the failure's trace, innermost first.
export fn em_trace(frame: *const Frame) void {
    trace.append(gpa, frame) catch outOfMemory();
}

fn write(bytes: []const u8) void {
    out_writer.interface.writeAll(bytes) catch {};
}

export fn em_write_text(bytes: [*]const u8, len: usize) void {
    write(bytes[0..len]);
}

export fn em_write_int(value: i64) void {
    out_writer.interface.print("{d}", .{value}) catch {};
}

export fn em_write_float(value: f64) void {
    Value.displayFloat(value, &out_writer.interface) catch {};
}

export fn em_write_bool(value: bool) void {
    write(if (value) "true" else "false");
}

/// `left op right` for two `Int`s, for an operation generated C does not do
/// itself or one that overflowed there.
export fn em_int_arithmetic(operator: c_int, left: i64, right: i64, result: *i64, site: *const Site) c_int {
    return call(site, Operations.intArithmetic, .{ @as(Operations.Arithmetic, @fromBackingInt(@intCast(operator))), left, right }, result);
}

export fn em_float_arithmetic(operator: c_int, left: f64, right: f64, result: *f64, site: *const Site) c_int {
    return call(site, Operations.floatArithmetic, .{ @as(Operations.Arithmetic, @fromBackingInt(@intCast(operator))), left, right }, result);
}

export fn em_negate(value: i64, result: *i64, site: *const Site) c_int {
    return call(site, Operations.negate, .{value}, result);
}

/// Section 5.3's exact comparison of an `Int` with a `Float`: -1, 0 or 1, or
/// 2 when they are unordered because the `Float` is NaN.
export fn em_compare_int_float(left: i64, right: f64) c_int {
    const order = Value.order(.initInt(left), .initFloat(right)) orelse return 2;
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// Strings (slice 3a). A `String` in generated C is a `*Heap.Text`, the
// interpreter's own representation, and a null one in a slot that holds
// nothing yet. Every slot owns one reference; generated C retains what it
// stores and releases what it overwrites, and each function releases its
// locals as it returns. What a function here gives back is owned by the
// caller; what it is passed is only borrowed.

fn textValue(text: *Heap.Text) Value {
    return .{ .data = .{ .string = text } };
}

export fn em_retain(text: ?*Heap.Text) void {
    if (text) |held| _ = Heap.retain(textValue(held));
}

export fn em_release(text: ?*Heap.Text) void {
    if (text) |held| heap.release(textValue(held));
}

/// The text of a string literal, made once and cached in `cell`. A literal is
/// never counted, so retaining and releasing it costs nothing.
export fn em_literal(cell: *?*Heap.Text, bytes: [*]const u8, len: usize) *Heap.Text {
    if (cell.*) |text| return text;
    const text = heap.literalText(bytes[0..len]) catch outOfMemory();
    cell.* = text;
    return text;
}

export fn em_write_string(text: *Heap.Text) void {
    write(text.bytes);
}

/// Section 9's `+`: a new string holding both.
export fn em_concat(left: *Heap.Text, right: *Heap.Text) *Heap.Text {
    const joined = std.mem.concat(gpa, u8, &.{ left.bytes, right.bytes }) catch outOfMemory();
    return heap.createText(joined) catch outOfMemory();
}

/// Section 9.2's comparison, by the code points of the normalized forms:
/// -1, 0 or 1.
export fn em_compare_strings(left: *Heap.Text, right: *Heap.Text) c_int {
    const order = @import("unicode.zig").order(gpa, left.bytes, right.bytes) catch outOfMemory();
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

export fn em_equal_strings(left: *Heap.Text, right: *Heap.Text) bool {
    return @import("unicode.zig").equal(gpa, left.bytes, right.bytes) catch outOfMemory();
}

/// Section 9.2's `count`: the characters, not the bytes.
export fn em_string_count(text: *Heap.Text) i64 {
    return @intCast(@import("unicode.zig").graphemeCount(text.bytes));
}

/// Section 9.1's `text[position]`, a one-character string.
export fn em_string_index(text: *Heap.Text, position: i64, result: **Heap.Text, site: *const Site) c_int {
    if (@import("strings.zig").characterAt(text.bytes, position)) |character| {
        result.* = (heap.copyText(character) catch outOfMemory()).data.string;
        return 0;
    }
    const count = @import("unicode.zig").graphemeCount(text.bytes);
    return call(site, Operations.outsideIndex, .{ Operations.Collection.string, count, position }, {});
}

/// Section 5.4's `text[start..end]` or `text[start..=end]`; a bound that was
/// not written is passed as `has_start` or `has_end` false.
export fn em_string_slice(text: *Heap.Text, has_start: bool, start: i64, has_end: bool, end: i64, inclusive: bool, result: **Heap.Text, site: *const Site) c_int {
    const count: i64 = @intCast(@import("unicode.zig").graphemeCount(text.bytes));
    var bounds: Operations.Bounds = undefined;
    const status = call(site, Operations.sliceBounds, .{ Operations.Collection.string, count, if (has_start) start else null, if (has_end) end else null, inclusive }, &bounds);
    if (status != 0) return status;
    const piece = @import("strings.zig").substring(text.bytes, @intCast(bounds.start), @intCast(bounds.end - bounds.start)) catch unreachable;
    result.* = (heap.copyText(piece) catch outOfMemory()).data.string;
    return 0;
}

/// Builds a string from parts, for an interpolation or a `to_string`.
const Builder = std.Io.Writer.Allocating;

export fn em_builder_new() *Builder {
    const builder = gpa.create(Builder) catch outOfMemory();
    builder.* = .init(gpa);
    return builder;
}

export fn em_builder_text(builder: *Builder, bytes: [*]const u8, len: usize) void {
    builder.writer.writeAll(bytes[0..len]) catch outOfMemory();
}

export fn em_builder_string(builder: *Builder, text: *Heap.Text) void {
    builder.writer.writeAll(text.bytes) catch outOfMemory();
}

export fn em_builder_int(builder: *Builder, value: i64) void {
    builder.writer.print("{d}", .{value}) catch outOfMemory();
}

export fn em_builder_float(builder: *Builder, value: f64) void {
    Value.displayFloat(value, &builder.writer) catch outOfMemory();
}

export fn em_builder_bool(builder: *Builder, value: bool) void {
    builder.writer.writeAll(if (value) "true" else "false") catch outOfMemory();
}

export fn em_builder_finish(builder: *Builder) *Heap.Text {
    const bytes = builder.toOwnedSlice() catch outOfMemory();
    gpa.destroy(builder);
    return heap.createText(bytes) catch outOfMemory();
}

/// A value crossing to a native: one of the kinds generated C holds so far,
/// in the order of `Value.Kind`.
pub const EmValue = extern struct {
    kind: u8,
    as: extern union {
        int: i64,
        float: f64,
        boolean: bool,
        text: ?*Heap.Text,
    },
};

fn fromC(value: EmValue) Value {
    return switch (@as(Value.Kind, @fromBackingInt(@intCast(value.kind)))) {
        .nothing => Value.nothing,
        .bool => .initBool(value.as.boolean),
        .int => .initInt(value.as.int),
        .float => .initFloat(value.as.float),
        .string => textValue(value.as.text.?),
        else => unreachable, // generated C holds no other kind yet
    };
}

fn toC(value: Value) EmValue {
    return switch (value.data) {
        .nothing => .{ .kind = @backingInt(Value.Kind.nothing), .as = .{ .int = 0 } },
        .bool => |truth| .{ .kind = @backingInt(Value.Kind.bool), .as = .{ .boolean = truth } },
        .int => |number| .{ .kind = @backingInt(Value.Kind.int), .as = .{ .int = number } },
        .float => |number| .{ .kind = @backingInt(Value.Kind.float), .as = .{ .float = number } },
        .string => |text| .{ .kind = @backingInt(Value.Kind.string), .as = .{ .text = text } },
        else => unreachable, // the compiler asks only for natives giving these
    };
}

/// A method of `Natives.zig`, by the index of its family in `Natives.Id`
/// and of the method in that family's enum, on `receiver` with `arguments`.
/// The result is the caller's to own, with the kind `expected` names, which
/// is the checker's type: an `Int` where a `Float` is expected is widened, as
/// the interpreter widens what it stores (section 4.4).
export fn em_native(family: c_int, method: c_int, receiver: EmValue, arguments: [*]const EmValue, count: usize, expected: u8, result: *EmValue, site: *const Site) c_int {
    const Natives = @import("Natives.zig");
    const id = idOf(Natives, @intCast(family), @intCast(method));
    var values: [8]Value = undefined;
    for (arguments[0..count], values[0..count]) |argument, *value| value.* = fromC(argument);
    var answer: Value = undefined;
    const status = call(site, Natives.call, .{ id, fromC(receiver), values[0..count] }, &answer);
    if (status == 0) result.* = toC(Native.widen(answer, @fromBackingInt(@intCast(expected))));
    return status;
}

fn idOf(comptime Natives: type, family: usize, method: usize) Natives.Id {
    const tag: Natives.Family = @fromBackingInt(@intCast(family));
    return switch (tag) {
        inline else => |known| @unionInit(Natives.Id, @tagName(known), @fromBackingInt(@intCast(method))),
    };
}
