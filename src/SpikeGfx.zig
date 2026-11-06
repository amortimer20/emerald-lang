//! SPIKE ONLY (docs/vendor-libraries-design-plan.md, slice 0). Loads the
//! raylib module named by EMERALD_SPIKE_LIB the first time a Gfx native runs
//! and calls its C-ABI functions. Never merged.
const std = @import("std");
const builtin = @import("builtin");

pub const Fns = struct {
    open: *const fn (i64, i64, bool) callconv(.c) bool,
    close: *const fn () callconv(.c) void,
    should_close: *const fn () callconv(.c) bool,
    begin: *const fn () callconv(.c) void,
    end: *const fn () callconv(.c) void,
    circle: *const fn (i64, i64, f64, i64) callconv(.c) void,
    rect: *const fn (i64, i64, i64, i64, i64) callconv(.c) void,
    fps: *const fn () callconv(.c) i64,
    checksum: *const fn () callconv(.c) i64,
};

// Zig 0.17's std.DynLib has no Windows implementation, so the spike asks the
// system loader directly there.
const win = struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

var fns: ?Fns = null;
pub var calls: u64 = 0;

pub fn loaded() ?*const Fns {
    return if (fns) |*table| table else null;
}

pub fn load(path: []const u8) !*const Fns {
    if (fns) |*existing| return existing;
    var table: Fns = undefined;
    if (builtin.os.tag == .windows) {
        var buffer: [1024:0]u8 = undefined;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const module = win.LoadLibraryA(&buffer) orelse return error.LibraryNotFound;
        inline for (comptime std.meta.fieldNames(Fns)) |name| {
            const address = win.GetProcAddress(module, "spike_" ++ name) orelse return error.MissingSymbol;
            @field(table, name) = @ptrCast(@alignCast(address));
        }
    } else {
        var opened = try std.DynLib.open(path);
        inline for (comptime std.meta.fieldNames(Fns)) |name| {
            @field(table, name) = opened.lookup(@FieldType(Fns, name), "spike_" ++ name) orelse return error.MissingSymbol;
        }
    }
    fns = table;
    return &fns.?;
}
