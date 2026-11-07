//! Section 15.8's time-zone natives (`Native.zig`), over the database built
//! into Emerald (`TimeZone.zig`) and the machine's own zone.

const std = @import("std");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const TimeZone = @import("TimeZone.zig");

const Context = Native.Context;
const Error = Native.Error;

/// The rules a zone name has, for a zone whose offset changes: the built-in
/// database's first, so a name means the same everywhere, then the machine's
/// own rules for a local zone the database does not know.
pub fn zoneRules(ctx: *Context, name: []const u8) Error!?TimeZone.Rules {
    if (ctx.state.zone_cache.get(name)) |rules| return rules;
    const database = try zoneDatabase(ctx);
    const found = (database.rules(ctx.arena, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    }) orelse {
        const local = ctx.state.local_zone.rules orelse return null;
        return if (std.mem.eql(u8, name, ctx.state.local_zone.name)) local else null;
    };
    try ctx.state.zone_cache.put(ctx.arena, try ctx.arena.dupe(u8, name), found);
    return found;
}

pub fn zoneDatabase(ctx: *Context) Error!TimeZone.Database {
    if (ctx.state.zone_database) |database| return database;
    // The embedded file is generated and checked by its unit test, so only
    // running out of memory can stop it loading.
    const database = TimeZone.Database.load(ctx.arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    ctx.state.zone_database = database;
    return database;
}

/// The offset in seconds from UTC of zone `name` at instant `at` (seconds
/// since 1970), or 0 for a zone this machine does not know.
pub fn zoneOffset(ctx: *Context, name: []const u8, at: i64) Error!Value {
    const rules = try zoneRules(ctx, name) orelse return .initInt(0);
    return .initInt(rules.offsetAt(at));
}

/// The known zone name closest to `name`, for a "did you mean" help.
pub fn zoneSuggestion(ctx: *Context, name: []const u8) Error!Value {
    const database = try zoneDatabase(ctx);
    const closest = database.closest(name) orelse return .nothing;
    return ctx.heap.copyText(closest);
}
