//! Vendor libraries' native modules (docs/vendor-libraries-design-plan.md,
//! decisions 2 and 3): shared libraries that Emerald loads the first time a
//! program calls into one. The interface is `vendor/emerald_module.h`; this
//! file is its Zig side and the loader.
const std = @import("std");
const builtin = @import("builtin");

pub const abi_version: u32 = 1;

pub const Kind = enum(u32) { nothing = 0, bool = 1, int = 2, float = 3, text = 4, bytes = 5, @"error" = 6 };

pub const Bytes = extern struct { data: ?[*]const u8, length: usize };

pub const Value = extern struct {
    kind: Kind,
    as: extern union {
        boolean: u8,
        integer: i64,
        number: f64,
        bytes: Bytes,
    },

    pub const nothing: Value = .{ .kind = .nothing, .as = .{ .integer = 0 } };
    pub fn fromBool(flag: bool) Value {
        return .{ .kind = .bool, .as = .{ .boolean = @intFromBool(flag) } };
    }
    pub fn fromInt(number: i64) Value {
        return .{ .kind = .int, .as = .{ .integer = number } };
    }
    pub fn fromFloat(number: f64) Value {
        return .{ .kind = .float, .as = .{ .number = number } };
    }
    pub fn fromText(bytes: []const u8) Value {
        return .{ .kind = .text, .as = .{ .bytes = .{ .data = bytes.ptr, .length = bytes.len } } };
    }
    pub fn fromBytes(bytes: []const u8) Value {
        return .{ .kind = .bytes, .as = .{ .bytes = .{ .data = bytes.ptr, .length = bytes.len } } };
    }
    /// The bytes of a text, bytes, or error value.
    pub fn slice(self: Value) []const u8 {
        const data = self.as.bytes.data orelse return "";
        return data[0..self.as.bytes.length];
    }
};

pub const Native = *const fn (arguments: [*]const Value, count: usize) callconv(.c) Value;

pub const Entry = extern struct { name: [*:0]const u8, function: Native };

pub const Table = extern struct {
    abi_version: u32,
    library: [*:0]const u8,
    entries: [*]const Entry,
    entry_count: usize,
    shutdown: ?*const fn () callconv(.c) void,
};

const Export = *const fn (host_abi_version: u32) callconv(.c) ?*const Table;

/// Whether this build can load a module. Zig's own ELF loader, used when the
/// program does not link the C library, cannot load a library that has its own
/// dependencies, so a static Linux build loads none.
pub const supported = switch (builtin.os.tag) {
    .windows => true,
    .linux => builtin.link_libc and !(builtin.abi.isMusl() and builtin.link_mode == .static),
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// Directories searched for a module, in order. The command line sets them
/// from `EMERALD_MODULE_PATH` and the directory beside the executable.
pub var search_dirs: []const []const u8 = &.{};

pub const LoadError = error{ Unsupported, NotFound, BadModule, WrongVersion, OutOfMemory };

/// A loaded module table. Loading is not undone: a module lives until the
/// program ends, when `shutdownAll` calls its shutdown.
pub const Loaded = struct {
    table: *const Table,

    pub fn find(self: Loaded, name: []const u8) ?Native {
        for (self.table.entries[0..self.table.entry_count]) |entry| {
            if (std.mem.eql(u8, std.mem.span(entry.name), name)) return entry.function;
        }
        return null;
    }
};

const win = struct {
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

/// The file name of the library named `stem` (`emerald-selftest`).
pub fn fileName(arena: std.mem.Allocator, stem: []const u8) std.mem.Allocator.Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => std.fmt.allocPrint(arena, "{s}.dll", .{stem}),
        .macos => std.fmt.allocPrint(arena, "lib{s}.dylib", .{stem}),
        else => std.fmt.allocPrint(arena, "lib{s}.so", .{stem}),
    };
}

/// Loads the module whose library is `stem`, searching `search_dirs`. Memory
/// for paths comes from `scratch`, which the caller may reset afterwards.
pub fn load(scratch: std.mem.Allocator, stem: []const u8) LoadError!Loaded {
    if (!supported) return error.Unsupported;
    const file_name = try fileName(scratch, stem);
    for (search_dirs) |directory| {
        const path = try std.fs.path.join(scratch, &.{ directory, file_name });
        if (openAt(scratch, path)) |loaded| return loaded else |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        }
    }
    return error.NotFound;
}

fn openAt(scratch: std.mem.Allocator, path: []const u8) LoadError!Loaded {
    const symbol: ?Export = switch (builtin.os.tag) {
        .windows => blk: {
            const wide = std.unicode.utf8ToUtf16LeAllocZ(scratch, path) catch return error.OutOfMemory;
            const handle = win.LoadLibraryW(wide) orelse return error.NotFound;
            const address = win.GetProcAddress(handle, "emerald_module") orelse return error.BadModule;
            break :blk @ptrCast(@alignCast(address));
        },
        else => blk: {
            const path_z = scratch.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
            var library = std.DynLib.openZ(path_z) catch return error.NotFound;
            break :blk library.lookup(Export, "emerald_module") orelse {
                library.close();
                return error.BadModule;
            };
        },
    };
    const table = (symbol orelse return error.BadModule)(abi_version) orelse return error.WrongVersion;
    if (table.abi_version != abi_version) return error.WrongVersion;
    return .{ .table = table };
}

/// Calls the shutdown of each module in `loaded`, in reverse order.
pub fn shutdownAll(loaded: []const Loaded) void {
    var index = loaded.len;
    while (index > 0) {
        index -= 1;
        if (loaded[index].table.shutdown) |shutdown| shutdown();
    }
}
