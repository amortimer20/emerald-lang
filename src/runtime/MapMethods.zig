//! Dictionary and set methods that read their receiver and call no block, as
//! natives (`Native.zig`). A key type's own `equals()` and `hash()` run
//! through the engine's callbacks.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const strings = @import("strings.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;
const widen = Native.widen;

/// Which half of a dictionary's entries `keys` or `values` asks for.
pub const Half = enum { key, value };
const FloatMath = @import("FloatMath.zig");
const Range = @import("Range.zig").Range;
const toFloat = Native.toFloat;
const holdsNan = Native.holdsNan;

/// Section 8.5's dictionary and set methods that only look.
/// Every dictionary and set method these natives answer, by name.
pub const Method = enum { @"empty?", @"union", intersection, difference, symmetric_difference, @"subset?", @"superset?", @"disjoint?", @"contains_key?", @"contains?", @"contains_value?", keys, values, entries };

pub fn readMap(
    ctx: *Context,
    method: Method,
    map: *const Heap.Map,
    arguments: []const Value,
) Error!Value {
    if (method == .@"empty?") return .initBool(map.count() == 0);

    if (map.is_set) {
        if (method == .@"union" or
            method == .intersection or
            method == .difference or
            method == .symmetric_difference)
        {
            const other = arguments[0];
            if (other.kind() != .map or !other.data.map.is_set) {
                return ctx.raiseFmt(
                    "`{s}` needs a Set",
                    .{@tagName(method)},
                    "Pass a set with the same element type.",
                );
            }
            const result = try ctx.heap.createMap(map.key_kind, .nothing, true);
            const value: Value = .{ .data = .{ .map = result } };
            errdefer ctx.heap.release(value);
            if (method == .@"union") {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try hashKey(ctx, key);
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
                for (other.data.map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try hashKey(ctx, key);
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
                return value;
            }
            if (method == .intersection) {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try hashKey(ctx, key);
                    if (try Heap.lookupIn(ctx.gpa, other.data.map, hash, key, ctx.equatable()) == null) continue;
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
                return value;
            }
            if (method == .difference) {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try hashKey(ctx, key);
                    if (try Heap.lookupIn(ctx.gpa, other.data.map, hash, key, ctx.equatable()) != null) continue;
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
                return value;
            }
            for (map.entries.items) |entry| {
                const key = Heap.retain(entry.key);
                const hash = try hashKey(ctx, key);
                if (try Heap.lookupIn(ctx.gpa, other.data.map, hash, key, ctx.equatable()) == null) {
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
            }
            for (other.data.map.entries.items) |entry| {
                const key = Heap.retain(entry.key);
                const hash = try hashKey(ctx, key);
                if (try Heap.lookupIn(ctx.gpa, map, hash, key, ctx.equatable()) == null) {
                    try ctx.heap.put(result, hash, key, Value.nothing, ctx.equatable());
                }
            }
            return value;
        }

        if (method == .@"subset?" or method == .@"superset?" or method == .@"disjoint?") {
            const other = arguments[0];
            if (other.kind() != .map or !other.data.map.is_set) {
                return ctx.raiseFmt(
                    "`{s}` needs a Set",
                    .{@tagName(method)},
                    "Pass a set with the same element type.",
                );
            }
            if (method == .@"subset?") {
                for (map.entries.items) |entry| {
                    const hash = try hashKey(ctx, entry.key);
                    if (try Heap.lookupIn(ctx.gpa, other.data.map, hash, entry.key, ctx.equatable()) == null) return .initBool(false);
                }
                return .initBool(true);
            }
            if (method == .@"superset?") {
                for (other.data.map.entries.items) |entry| {
                    const hash = try hashKey(ctx, entry.key);
                    if (try Heap.lookupIn(ctx.gpa, map, hash, entry.key, ctx.equatable()) == null) return .initBool(false);
                }
                return .initBool(true);
            }
            for (map.entries.items) |entry| {
                const hash = try hashKey(ctx, entry.key);
                if (try Heap.lookupIn(ctx.gpa, other.data.map, hash, entry.key, ctx.equatable()) != null) return .initBool(false);
            }
            return .initBool(true);
        }
    }

    if (method == .@"contains_key?" or method == .@"contains?") {
        const key = widen(Heap.retain(arguments[0]), map.key_kind);
        defer ctx.heap.release(key);
        const hash = try hashKey(ctx, key);
        return .initBool(try Heap.lookupIn(ctx.gpa, map, hash, key, ctx.equatable()) != null);
    }

    if (method == .@"contains_value?") {
        for (map.entries.items) |entry| {
            if (try Value.equals(ctx.gpa, entry.value, arguments[0], ctx.equatable())) return .initBool(true);
        }
        return .initBool(false);
    }

    if (method == .keys) return mapHalf(ctx.heap, map, .key);
    if (method == .values) return mapHalf(ctx.heap, map, .value);

    // `entries`
    const items = try collectItems(ctx.heap, map);
    defer ctx.gpa.free(items);
    const list = try ctx.heap.createList(.tuple, items.len);
    for (items) |item| list.items.appendAssumeCapacity(item);
    return .{ .data = .{ .list = list } };
}

/// Section 8.5's `keys` and `values`, each a list in insertion order.
fn mapHalf(heap: *Heap, map: *const Heap.Map, half: Half) Error!Value {
    const list = try heap.createList(
        if (half == .key) map.key_kind else map.value_kind,
        map.entries.items.len,
    );
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);
    for (map.entries.items) |entry| {
        list.items.appendAssumeCapacity(Heap.retain(if (half == .key) entry.key else entry.value));
    }
    return result;
}

/// Section 8.5's `each` and section 8.6's callback collection methods.
///
/// The receiver is held for the whole traversal, so the list being visited
/// cannot change underneath it: a block that changes the same variable finds
/// the buffer shared and copies it first, which is section 8.1's value
/// semantics doing exactly what it promises.
/// One value per entry: the member for a set, a `(key, value)` tuple for a
/// dictionary. The caller owns one holder of each.
pub fn collectItems(heap: *Heap, map: *const Heap.Map) Error![]Value {
    const items = try heap.gpa.alloc(Value, map.entries.items.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| heap.release(item);
        heap.gpa.free(items);
    }
    while (built < items.len) : (built += 1) {
        const entry = map.entries.items[built];
        items[built] = if (map.is_set)
            Heap.retain(entry.key)
        else
            try entryTuple(heap, map, .{
                .hash = entry.hash,
                .key = Heap.retain(entry.key),
                .value = Heap.retain(entry.value),
            });
    }
    return items;
}

/// Section 8.6's `(key, value)`, which is the one item a dictionary's block and
/// `for` loop receive. Takes over one holder of each half.
pub fn entryTuple(heap: *Heap, map: *const Heap.Map, entry: Heap.Map.Entry) Error!Value {
    const items = heap.gpa.alloc(Value, 2) catch |err| {
        heap.release(entry.key);
        heap.release(entry.value);
        return err;
    };
    items[0] = entry.key;
    items[1] = entry.value;
    const kinds = heap.gpa.alloc(Value.Kind, 2) catch |err| {
        for (items) |item| heap.release(item);
        heap.gpa.free(items);
        return err;
    };
    kinds[0] = map.key_kind;
    kinds[1] = map.value_kind;
    // `createTuple` takes over both halves even when it fails.
    return .{ .data = .{ .tuple = try heap.createTuple(items, kinds) } };
}

/// Section 8.3: NaN is rejected as a key, directly or inside a tuple, because
/// it is not equal to itself and so could never be found again.
pub fn hashKey(ctx: *Context, key: Value) Error!u64 {
    if (holdsNan(key)) return ctx.raise(
        "a not-a-number value cannot be a key",
        "`nan?` is never equal to anything, including itself, so nothing stored under it could be found again.",
    );
    return Value.hash(ctx.gpa, key, ctx.equatable());
}

/// Section 8.5's methods that change a dictionary or set in place. The
/// engine has made the map its own before calling (`Heap.uniqueMap`); the
/// arguments stay the engine's, and what is stored is retained here.
pub const Change = enum { add, remove, merge };

pub fn change(ctx: *Context, map: *Heap.Map, method: Change, arguments: []const Value) Error!Value {
    switch (method) {
        .add => {
            const held = widen(Heap.retain(arguments[0]), map.key_kind);
            const hash = hashKey(ctx, held) catch |err| {
                ctx.heap.release(held);
                return err;
            };
            try ctx.heap.put(map, hash, held, Value.nothing, ctx.equatable());
            return Value.nothing;
        },
        .remove => {
            const key = widen(Heap.retain(arguments[0]), map.key_kind);
            defer ctx.heap.release(key);
            const hash = try hashKey(ctx, key);
            const removed = try ctx.heap.removeKey(map, hash, key, ctx.equatable());
            // A set reports nothing; a dictionary answers with what was there,
            // and absence when the key was not (4.5).
            if (map.is_set) {
                if (removed) |value| ctx.heap.release(value);
                return Value.nothing;
            }
            return removed orelse Value.nothing;
        },
        .merge => {
            // The other dictionary's entries are copied first, because merging
            // one into itself would otherwise walk a list growing underneath it.
            const other = arguments[0].data.map;
            const entries = try ctx.gpa.dupe(Heap.Map.Entry, other.entries.items);
            defer ctx.gpa.free(entries);
            for (entries) |entry| {
                try ctx.heap.put(map, entry.hash, Heap.retain(entry.key), widen(Heap.retain(entry.value), map.value_kind), ctx.equatable());
            }
            return Value.nothing;
        },
    }
}
