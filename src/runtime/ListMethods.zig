//! The list methods that read their receiver and call no block, as natives
//! (`Native.zig`). A type's own `equals()`, `hash()` and `compare()` run
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
const FloatMath = @import("FloatMath.zig");
const Range = @import("Range.zig").Range;
const toFloat = Native.toFloat;
const holdsNan = Native.holdsNan;
const integer_range_help = Native.integer_range_help;
const Operations = @import("Operations.zig");

/// Which operation could not order a NaN, which decides the message.
pub const ExtremeKind = enum { ordinary, keyed, pair, sort, sort_by };

/// A list method that does not change its receiver. Value-producing methods
/// retain their items into a fresh list, preserving list value semantics even
/// when an item is itself a collection or object.
/// Every list method these natives answer, by name.
pub const Method = enum { @"empty?", @"contains?", index_of, chain, chunks, windows, pairs, take, drop, repeat, reverse, unique, zip, sum, average, min, max, sort, shuffle, random, join };

pub fn readListMethod(ctx: *Context, list: *const Heap.List, method: Method, arguments: []const Value) Error!Value {
    const items = list.items.items;
    return switch (method) {
        .@"empty?" => .initBool(items.len == 0),
        .@"contains?" => blk: {
            for (items) |item| {
                if (try Value.equals(ctx.gpa, item, arguments[0], ctx.equatable())) break :blk .initBool(true);
            }
            break :blk .initBool(false);
        },
        .index_of => blk: {
            for (items, 0..) |item, position| {
                if (try Value.equals(ctx.gpa, item, arguments[0], ctx.equatable())) break :blk .initInt(@intCast(position));
            }
            break :blk Value.nothing;
        },
        .chain => blk: {
            const other = arguments[0];
            if (other.kind() != .list) return ctx.raise(
                "`chain` needs a List, but this is not a List",
                "Pass another List to keep the same element type and append it on the end.",
            );
            const right = other.data.list;
            const result = try ctx.heap.createList(list.element, items.len + right.items.items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            for (right.items.items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            break :blk value;
        },
        .chunks => blk: {
            const width = arguments[0].data.int;
            if (width < 1) return ctx.raiseFmt(
                "`chunks` cannot use size {d}",
                .{width},
                "Pass a whole number greater than 0, as in `items.chunks(3)`.",
            );
            const result = try ctx.heap.createList(.list, if (items.len == 0) 0 else (items.len + @as(usize, @intCast(width)) - 1) / @as(usize, @intCast(width)));
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            var start: usize = 0;
            while (start < items.len) : (start += @as(usize, @intCast(width))) {
                const end = @min(start + @as(usize, @intCast(width)), items.len);
                const chunk = try copyList(ctx.heap, list.element, items[start..end]);
                result.items.appendAssumeCapacity(chunk);
            }
            break :blk value;
        },
        .windows => blk: {
            const width = arguments[0].data.int;
            if (width < 1) return ctx.raiseFmt(
                "`windows` cannot use size {d}",
                .{width},
                "Pass a whole number greater than 0, as in `items.windows(2)`.",
            );
            const count: usize = if (width > items.len) 0 else items.len - @as(usize, @intCast(width)) + 1;
            const result = try ctx.heap.createList(.list, count);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            var start: usize = 0;
            while (start + @as(usize, @intCast(width)) <= items.len) : (start += 1) {
                const chunk = try copyList(ctx.heap, list.element, items[start .. start + @as(usize, @intCast(width))]);
                result.items.appendAssumeCapacity(chunk);
            }
            break :blk value;
        },
        .pairs => blk: {
            const count: usize = if (items.len == 0) 0 else items.len - 1;
            const result = try ctx.heap.createList(.tuple, count);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            if (count > 0) {
                for (items[0..count], items[1..]) |left, right| {
                    const tuple_items = try ctx.gpa.alloc(Value, 2);
                    const tuple_kinds = ctx.gpa.alloc(Value.Kind, 2) catch |err| {
                        ctx.gpa.free(tuple_items);
                        return err;
                    };
                    tuple_items[0] = Heap.retain(left);
                    tuple_items[1] = Heap.retain(right);
                    tuple_kinds[0] = list.element;
                    tuple_kinds[1] = list.element;
                    const tuple = try ctx.heap.createTuple(tuple_items, tuple_kinds);
                    result.items.appendAssumeCapacity(.{ .data = .{ .tuple = tuple } });
                }
            }
            break :blk value;
        },
        .take, .drop => blk: {
            const requested = arguments[0].data.int;
            if (requested < 0) return ctx.raiseFmt(
                "`{s}` cannot use count {d}",
                .{ @tagName(method), requested },
                "Pass 0 or more items to take or drop.",
            );
            // A count larger than the machine can address still means "all"
            // here, so this stays independent of the interpreter's word size.
            const boundary = if (std.math.cast(usize, requested)) |count| @min(count, items.len) else items.len;
            break :blk if (method == .take)
                copyList(ctx.heap, list.element, items[0..boundary])
            else
                copyList(ctx.heap, list.element, items[boundary..]);
        },
        .repeat => blk: {
            const times = arguments[0].data.int;
            if (times < 0) return ctx.raiseFmt(
                "a List cannot be repeated {d} times",
                .{times},
                "Repeat it 0 or more times; 0 gives an empty List.",
            );
            // As for `String.repeat`, a result too large to address is as
            // unrepresentable as one too large to allocate. An empty List
            // repeated any number of times is still empty, without counting.
            if (items.len == 0) break :blk copyList(ctx.heap, list.element, items);
            const size = std.math.mul(usize, items.len, @intCast(times)) catch return error.OutOfMemory;
            const result = try ctx.heap.createList(list.element, size);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            for (0..@intCast(times)) |_| {
                for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            }
            break :blk value;
        },
        .reverse => blk: {
            const result = try ctx.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            var index = items.len;
            while (index > 0) {
                index -= 1;
                result.items.appendAssumeCapacity(Heap.retain(items[index]));
            }
            break :blk value;
        },
        .unique => blk: {
            const result = try ctx.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            outer: for (items) |item| {
                for (result.items.items) |previous| {
                    if (try Value.equals(ctx.gpa, item, previous, ctx.equatable())) continue :outer;
                }
                result.items.appendAssumeCapacity(Heap.retain(item));
            }
            break :blk value;
        },
        .zip => blk: {
            const other = arguments[0];
            if (other.kind() != .list) return ctx.raise(
                "`zip` needs a List, but this is not a List",
                "Pass another List to pair the items up.",
            );
            const right = other.data.list;
            const limit = @min(items.len, right.items.items.len);
            const result = try ctx.heap.createList(.tuple, limit);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            for (items[0..limit], right.items.items[0..limit]) |left, right_item| {
                const tuple_items = try ctx.gpa.alloc(Value, 2);
                const tuple_kinds = ctx.gpa.alloc(Value.Kind, 2) catch |err| {
                    ctx.gpa.free(tuple_items);
                    return err;
                };
                tuple_items[0] = Heap.retain(left);
                tuple_items[1] = Heap.retain(right_item);
                tuple_kinds[0] = list.element;
                tuple_kinds[1] = right.element;
                const tuple = try ctx.heap.createTuple(tuple_items, tuple_kinds);
                result.items.appendAssumeCapacity(.{ .data = .{ .tuple = tuple } });
            }
            break :blk value;
        },
        .sum => sumList(ctx, list),
        .join => blk: {
            const separator = if (arguments.len == 1) arguments[0].data.string.bytes else "";
            var joined: std.ArrayList(u8) = .empty;
            errdefer joined.deinit(ctx.gpa);
            for (items, 0..) |item, index| {
                if (index > 0) try joined.appendSlice(ctx.gpa, separator);
                try joined.appendSlice(ctx.gpa, item.data.string.bytes);
            }
            break :blk ctx.ownedText(try joined.toOwnedSlice(ctx.gpa));
        },
        .average => averageList(list),
        .min, .max => listExtreme(ctx, list, method == .min),
        .sort => blk: {
            if (list.element == .float and items.len > 0 and std.math.isNan(items[0].data.float)) return raiseExtremeNaN(ctx, .sort);
            const result = try ctx.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            try sortItemsByKeys(ctx, list.element, result.items.items, null, .sort);
            break :blk value;
        },
        .shuffle => blk: {
            const result = try ctx.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer ctx.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            ctx.random().shuffle(Value, result.items.items);
            break :blk value;
        },
        .random => if (items.len == 0) Value.nothing else Heap.retain(items[ctx.random().uintLessThan(usize, items.len)]),
    };
}

/// Section 8.6's first aggregation. Empty numeric Lists have the additive
/// identity, and Int accumulation uses the same checked arithmetic as `+`.
fn sumList(ctx: *Context, list: *const Heap.List) Error!Value {
    return switch (list.element) {
        .int => blk: {
            var total: i64 = 0;
            for (list.items.items) |item| {
                const added = @addWithOverflow(total, item.data.int);
                if (added[1] != 0) return ctx.raiseFmt(
                    "`sum` overflows Int while adding {d} and {d}",
                    .{ total, item.data.int },
                    integer_range_help,
                );
                total = added[0];
            }
            break :blk .initInt(total);
        },
        .float => blk: {
            var total: f64 = 0.0;
            for (list.items.items) |item| total += item.data.float;
            break :blk .initFloat(total);
        },
        else => unreachable, // The checker permits `sum` only on numeric Lists.
    };
}

/// A stable sort for `sort`, `sort!`, and `sort_by`, whose comparisons may
/// themselves fail — a `NaN` float, or a user `Ordered.compare` that raises.
/// `keys`, when given, is reordered in lock step with `items`, so `sort_by`'s
/// already-computed keys stay lined up with the items they came from; without
/// one, `items` is compared directly. It is stable, so items whose keys tie
/// keep their input order, matching every other List traversal (8.6).
///
/// Short runs are insertion-sorted, then merged in rounds of doubling width,
/// so a long list costs O(n log n) comparisons rather than insertion sort's
/// O(n²). Values only move, never gain or lose a reference, and a merge
/// writes to scratch space before copying back, so a comparison that fails
/// partway leaves `items` a complete permutation of what it held.
pub fn sortItemsByKeys(
    ctx: *Context,
    kind: Value.Kind,
    items: []Value,
    keys: ?[]Value,
    extreme: ExtremeKind,
) Error!void {
    const run_length: usize = 16;
    var start: usize = 0;
    while (start < items.len) : (start += run_length) {
        const end = @min(start + run_length, items.len);
        try insertionSort(ctx, kind, items[start..end], if (keys) |k| k[start..end] else null, extreme);
    }
    if (items.len <= run_length) return;

    const scratch = try ctx.gpa.alloc(Value, items.len);
    defer ctx.gpa.free(scratch);
    const key_scratch: ?[]Value = if (keys != null) try ctx.gpa.alloc(Value, items.len) else null;
    defer if (key_scratch) |spare| ctx.gpa.free(spare);

    var width: usize = run_length;
    while (width < items.len) : (width *= 2) {
        var left: usize = 0;
        while (left + width < items.len) : (left += 2 * width) {
            const middle = left + width;
            const right = @min(left + 2 * width, items.len);
            var a = left;
            var b = middle;
            var out = left;
            while (a < middle and b < right) : (out += 1) {
                const first = if (keys) |k| k[a] else items[a];
                const second = if (keys) |k| k[b] else items[b];
                // Take from the right half only when it is strictly smaller,
                // so equal keys keep their order.
                const from = if (try orderListItems(ctx, kind, first, second, extreme) == .gt) &b else &a;
                scratch[out] = items[from.*];
                if (keys) |k| key_scratch.?[out] = k[from.*];
                from.* += 1;
            }
            for (a..middle) |index| {
                scratch[out] = items[index];
                if (keys) |k| key_scratch.?[out] = k[index];
                out += 1;
            }
            for (b..right) |index| {
                scratch[out] = items[index];
                if (keys) |k| key_scratch.?[out] = k[index];
                out += 1;
            }
            @memcpy(items[left..right], scratch[left..right]);
            if (keys) |k| @memcpy(k[left..right], key_scratch.?[left..right]);
        }
    }
}

pub fn orderListItems(ctx: *Context, kind: Value.Kind, left: Value, right: Value, extreme: ExtremeKind) Error!std.math.Order {
    return switch (kind) {
        .int => std.math.order(left.data.int, right.data.int),
        .float => {
            if (std.math.isNan(left.data.float) or std.math.isNan(right.data.float)) return raiseExtremeNaN(ctx, extreme);
            return std.math.order(left.data.float, right.data.float);
        },
        .string => unicode.order(ctx.gpa, left.data.string.bytes, right.data.string.bytes),
        .struct_value => blk: {
            const compared = try ctx.compare(left, right);
            defer ctx.heap.release(compared);
            break :blk std.math.order(compared.data.int, 0);
        },
        else => unreachable, // The checker permits ordering only Ints, Floats, Strings, and `Ordered` structs.
    };
}

/// The stable insertion sort `sortItemsByKeys` runs on each short run.
fn insertionSort(
    ctx: *Context,
    kind: Value.Kind,
    items: []Value,
    keys: ?[]Value,
    extreme: ExtremeKind,
) Error!void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const left = if (keys) |k| k[j - 1] else items[j - 1];
            const right = if (keys) |k| k[j] else items[j];
            if (try orderListItems(ctx, kind, left, right, extreme) != .gt) break;
            std.mem.swap(Value, &items[j - 1], &items[j]);
            if (keys) |k| std.mem.swap(Value, &k[j - 1], &k[j]);
            j -= 1;
        }
    }
}

/// Section 8.6's extrema. Ties retain the first item, and an empty List has no
/// result. The checker has already limited this to the same orderable types as
/// ordinary comparisons; NaN is the one numeric value with no order at all.
fn listExtreme(ctx: *Context, list: *const Heap.List, minimum: bool) Error!Value {
    const items = list.items.items;
    if (items.len == 0) return Value.nothing;
    if (list.element == .float and std.math.isNan(items[0].data.float)) return ctx.raise(
        "`min` and `max` cannot order a List containing NaN",
        "Check values with `nan?()` before choosing a minimum or maximum.",
    );

    var chosen = Heap.retain(items[0]);
    errdefer ctx.heap.release(chosen);
    for (items[1..]) |item| {
        const ordering = try orderListItems(ctx, chosen.data, chosen, item, .ordinary);
        const replace = if (minimum) ordering == .gt else ordering == .lt;
        if (!replace) continue;
        ctx.heap.release(chosen);
        chosen = Heap.retain(item);
    }
    return chosen;
}

/// A new list containing one held copy of each value in `items`.
pub fn copyList(heap: *Heap, element: Value.Kind, items: []const Value) Error!Value {
    const list = try heap.createList(element, items.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);
    for (items) |item| list.items.appendAssumeCapacity(Heap.retain(item));
    return result;
}

/// Section 8.6's numeric average. Its result is always Float so a fractional
/// answer from an Int List stays visible; no items have no average. Each item
/// widens as an ordinary Float operation would, then Float arithmetic supplies
/// the established Infinity and NaN behavior.
fn averageList(list: *const Heap.List) Error!Value {
    if (list.items.items.len == 0) return Value.nothing;
    var total: f64 = 0.0;
    switch (list.element) {
        .int => {
            for (list.items.items) |item| total += @floatFromInt(item.data.int);
        },
        .float => {
            for (list.items.items) |item| total += item.data.float;
        },
        else => unreachable, // The checker permits `average` only on numeric Lists.
    }
    return .initFloat(total / @as(f64, @floatFromInt(list.items.items.len)));
}

pub fn raiseExtremeNaN(ctx: *Context, kind: ExtremeKind) Error {
    return ctx.raise(
        switch (kind) {
            .ordinary => "`min` and `max` cannot order a List containing NaN",
            .keyed => "`min_by` and `max_by` cannot order a key of NaN",
            .pair => "`min_max` cannot order a List containing NaN",
            .sort => "`sort` cannot order a List containing NaN",
            .sort_by => "`sort_by` cannot order a key of NaN",
        },
        switch (kind) {
            .ordinary, .keyed, .pair => "Check values with `nan?()` before choosing a minimum or maximum.",
            .sort => "Check values with `nan?()` before sorting the List.",
            .sort_by => "Return a key that is not NaN, checking it with `nan?()` when needed.",
        },
    );
}

/// Section 8's methods that change a list in place. The engine has made the
/// list its own before calling (`Heap.unique`), and passes arguments it owns:
/// one stored, as `append`'s is, is kept, and one only compared is released.
pub const Mutation = enum { append, append_all, insert, remove, remove_all, remove_at, remove_first, remove_last, clear, @"reverse!", @"unique!", @"sort!", @"shuffle!" };

pub fn mutate(ctx: *Context, list: *Heap.List, method: Mutation, arguments: []const Value) Error!Value {
    const items = &list.items;
    switch (method) {
        .append => try items.append(ctx.gpa, widen(arguments[0], list.element)),
        .append_all => {
            // The argument was evaluated before the receiver was made unique,
            // so `items.append_all(items)` reads what the list held before
            // the call, never the items it is adding. Reading by position up
            // to the count taken first keeps that true even if both were one
            // list, whose storage growing would move.
            defer ctx.heap.release(arguments[0]);
            const added = arguments[0].data.list;
            const count = added.items.items.len;
            try items.ensureUnusedCapacity(ctx.gpa, count);
            for (0..count) |position| items.appendAssumeCapacity(widen(Heap.retain(added.items.items[position]), list.element));
        },
        .insert => {
            const index = arguments[0].data.int;
            if (index < 0 or index > items.items.len) {
                const count = items.items.len;
                const help = try std.fmt.allocPrint(
                    ctx.arena,
                    "Insert at 0 through {d}. Inserting at {d} adds to the end.",
                    .{ count, count },
                );
                return ctx.raiseFmt(
                    "cannot insert at index {d} in a list of {d} element{s}",
                    .{ index, count, if (count == 1) "" else "s" },
                    help,
                );
            }
            try items.insert(ctx.gpa, @intCast(index), widen(arguments[1], list.element));
        },
        .remove => {
            defer ctx.heap.release(arguments[0]);
            for (items.items, 0..) |item, position| {
                if (!try Value.equals(ctx.gpa, item, arguments[0], ctx.equatable())) continue;
                ctx.heap.release(items.orderedRemove(position));
                break;
            }
        },
        .remove_all => {
            defer ctx.heap.release(arguments[0]);
            const keep = try ctx.gpa.alloc(bool, items.items.len);
            defer ctx.gpa.free(keep);
            for (items.items, keep) |item, *kept| kept.* = !try Value.equals(ctx.gpa, item, arguments[0], ctx.equatable());
            compactList(ctx.heap, list, keep);
        },
        .remove_at => {
            const position = arguments[0].data.int;
            if (position < 0 or position >= items.items.len) return Operations.outsideIndex(ctx, .list, items.items.len, position);
            return items.orderedRemove(@intCast(position));
        },
        .remove_first, .remove_last => {
            if (items.items.len == 0) return ctx.raise(
                "cannot remove an element from an empty list",
                "Check `empty?()` first.",
            );
            return if (method == .remove_first) items.orderedRemove(0) else items.pop().?;
        },
        .clear => {
            for (items.items) |item| ctx.heap.release(item);
            items.clearRetainingCapacity();
        },
        .@"reverse!" => std.mem.reverse(Value, items.items),
        .@"unique!" => {
            const keep = try ctx.gpa.alloc(bool, items.items.len);
            defer ctx.gpa.free(keep);
            outer: for (items.items, 0..) |item, position| {
                keep[position] = true;
                for (items.items[0..position], keep[0..position]) |previous, kept| {
                    if (!kept) continue;
                    if (try Value.equals(ctx.gpa, item, previous, ctx.equatable())) {
                        keep[position] = false;
                        continue :outer;
                    }
                }
            }
            compactList(ctx.heap, list, keep);
        },
        .@"sort!" => {
            if (list.element == .float and items.items.len > 0 and std.math.isNan(items.items[0].data.float)) return raiseExtremeNaN(ctx, .sort);
            try sortItemsByKeys(ctx, list.element, items.items, null, .sort);
        },
        .@"shuffle!" => ctx.random().shuffle(Value, items.items),
    }
    return Value.nothing;
}

/// No user code runs during publication: decisions are complete before any
/// element is released or moved, so an error leaves scratch ownership valid.
pub fn compactList(heap: *Heap, list: *Heap.List, keep: []const bool) void {
    var count: usize = 0;
    for (list.items.items, keep) |item, kept| {
        if (kept) {
            list.items.items[count] = item;
            count += 1;
        } else heap.release(item);
    }
    list.items.shrinkRetainingCapacity(count);
}
