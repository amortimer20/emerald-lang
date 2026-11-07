//! Natives that ask the system or the terminal's text rules (`Native.zig`):
//! section 14.3's `Console` measurements, section 15.10's environment, and the
//! clocks under `Instant` and `Stopwatch`.

const std = @import("std");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;

/// The columns `text` takes in a terminal.
pub fn columnWidth(ctx: *Context, text: []const u8) Error!Value {
    return .initInt(@intCast(try unicode.columnWidth(ctx.gpa, text)));
}

/// `text` without its color and style sequences.
pub fn plainOf(ctx: *Context, text: []const u8) Error!Value {
    return ctx.ownedText(try plainText(ctx.gpa, text));
}

/// `text` without its complete ANSI SGR sequences, which is what Console's
/// styling adds, leaving any other control text alone.
pub fn plainText(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(gpa);
    var index: usize = 0;
    while (index < text.len) {
        if (unicode.sgrEnd(text, index)) |end| {
            index = end;
            continue;
        }
        try plain.append(gpa, text[index]);
        index += 1;
    }
    return plain.toOwnedSlice(gpa);
}

/// A clock reading in nanoseconds: since 1970 for `.real`, which fits `Int`
/// until 2262, and since some unspecified start for the monotonic `.awake`.
pub fn clock(ctx: *Context, which: std.Io.Clock) Error!Value {
    return .initInt(@intCast(which.now(ctx.io).toNanoseconds()));
}

/// Section 15.10's `Program.environment`: one variable's value, or `nothing`
/// when it is not set. No variable is named `""` or has `=` or a NUL in its
/// name, so asking for one is `nothing` too.
pub fn environment(ctx: *Context, environ: std.process.Environ, name: []const u8) Error!Value {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "=\x00") != null) return Value.nothing;
    var variables = std.process.Environ.createMap(environ, ctx.gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Only WASI can fail otherwise, and then nothing is readable.
        else => return Value.nothing,
    };
    defer variables.deinit();
    const value = variables.get(name) orelse return Value.nothing;
    // Windows gives WTF-8, which an unpaired surrogate leaves invalid UTF-8.
    if (!std.unicode.utf8ValidateSlice(value)) {
        const message = try std.fmt.allocPrint(ctx.arena, "the environment variable `{s}` is not valid UTF-8 text", .{name});
        return ctx.raiseTyped("EncodingError", message, "Set the variable to UTF-8 text before running the program.");
    }
    return ctx.heap.copyText(value);
}
