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
