//! Section 9.2's string methods, as natives (`Native.zig`): each takes the
//! receiver's bytes and evaluated arguments, and records its own failures.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const strings = @import("strings.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;
const widen = Native.widen;

/// Section 9.2's string methods, on the receiver's bytes. The checker has
/// proved the method exists and the arguments fit it.
pub fn stringMethod(ctx: *Context, bytes: []const u8, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        @"empty?",
        @"blank?",
        @"contains?",
        @"starts_with?",
        @"ends_with?",
        trim,
        trim_start,
        trim_end,
        upper,
        lower,
        capitalize,
        reverse,
        repeat,
        replace,
        insert_at,
        substring,
        remove_prefix,
        remove_suffix,
        collapse_repeats,
        pad_start,
        pad_end,
        pad_center,
        split,
        partition,
        lines,
        words,
        @"letter?",
        @"digit?",
        @"whitespace?",
        @"upper?",
        @"lower?",
        chars,
        code_points,
        bytes,
        index_of,
        to_int,
        to_int_or,
        to_int_maybe,
        to_float,
        to_float_or,
        to_float_maybe,
    };
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, name, "to_bytes")) return ctx.heap.copyBytes(bytes);
    return switch (std.meta.stringToEnum(Method, name).?) {
        .@"empty?" => .initBool(bytes.len == 0),
        .@"blank?" => .initBool(strings.isBlank(bytes)),
        .@"letter?" => .initBool(strings.everyCharacter(bytes, .letter)),
        .@"digit?" => .initBool(strings.everyCharacter(bytes, .digit)),
        .@"whitespace?" => .initBool(strings.everyCharacter(bytes, .whitespace)),
        .@"upper?" => .initBool(strings.everyCharacter(bytes, .upper)),
        .@"lower?" => .initBool(strings.everyCharacter(bytes, .lower)),
        .@"contains?" => .initBool(try strings.contains(gpa, bytes, arguments[0].data.string.bytes)),
        .@"starts_with?" => .initBool(try strings.startsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .@"ends_with?" => .initBool(try strings.endsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .trim => ctx.heap.copyText(strings.trim(bytes, .both)),
        .trim_start => ctx.heap.copyText(strings.trim(bytes, .start)),
        .trim_end => ctx.heap.copyText(strings.trim(bytes, .end)),
        .upper => ctx.ownedText(try unicode.mapCase(gpa, bytes, .upper)),
        .lower => ctx.ownedText(try unicode.mapCase(gpa, bytes, .lower)),
        .capitalize => ctx.ownedText(try strings.capitalize(gpa, bytes)),
        .reverse => ctx.ownedText(try strings.reverse(gpa, bytes)),
        .repeat => blk: {
            const times = arguments[0].data.int;
            if (times < 0) return ctx.raiseFmt(
                "a String cannot be repeated {d} times",
                .{times},
                "Repeat it 0 or more times; 0 gives an empty String.",
            );
            // A result too large to address is as unrepresentable as one too
            // large to allocate.
            const size = std.math.mul(usize, bytes.len, @intCast(times)) catch return error.OutOfMemory;
            const result = try gpa.alloc(u8, size);
            for (0..@intCast(times)) |copy| @memcpy(result[copy * bytes.len ..][0..bytes.len], bytes);
            break :blk ctx.ownedText(result);
        },
        .replace => blk: {
            const old = arguments[0].data.string.bytes;
            if (old.len == 0) return ctx.raise(
                "`replace` needs something to replace, but this is an empty String",
                "Pass the text to find as the first argument.",
            );
            break :blk ctx.ownedText(try strings.replace(gpa, bytes, old, arguments[1].data.string.bytes));
        },
        .insert_at => blk: {
            const index = arguments[0].data.int;
            const result = strings.insertAt(gpa, bytes, index, arguments[1].data.string.bytes) catch |err| {
                if (err == error.NegativeIndex or err == error.IndexPastEnd) return raiseInsert(ctx, bytes, index, @errorCast(err));
                return error.OutOfMemory;
            };
            break :blk ctx.ownedText(result);
        },
        .substring => blk: {
            const start = arguments[0].data.int;
            const count: ?i64 = if (arguments.len == 2) arguments[1].data.int else null;
            const slice = strings.substring(bytes, start, count) catch |err| return raiseSubstring(ctx, bytes, start, count, err);
            break :blk ctx.heap.copyText(slice);
        },
        .remove_prefix => ctx.heap.copyText(try strings.removePrefix(gpa, bytes, arguments[0].data.string.bytes)),
        .remove_suffix => ctx.heap.copyText(try strings.removeSuffix(gpa, bytes, arguments[0].data.string.bytes)),
        .collapse_repeats => ctx.ownedText(try strings.collapseRepeats(gpa, bytes)),
        .pad_start, .pad_end, .pad_center => blk: {
            const width = arguments[0].data.int;
            const fill = if (arguments.len == 2) arguments[1].data.string.bytes else " ";
            const side: strings.PadSide = switch (std.meta.stringToEnum(Method, name).?) {
                .pad_start => .start,
                .pad_end => .end,
                .pad_center => .center,
                else => unreachable,
            };
            const result = strings.pad(gpa, bytes, width, fill, side) catch |err| {
                if (err == error.NegativeWidth or err == error.EmptyFill or err == error.MultipleCharacterFill) return raisePadding(ctx, width, fill, @errorCast(err));
                return error.OutOfMemory;
            };
            break :blk ctx.ownedText(result);
        },
        .split => blk: {
            const separator = arguments[0].data.string.bytes;
            if (separator.len == 0) return ctx.raise(
                "`split` needs a separator, but this is an empty String",
                "Use `chars()` to split a String into its characters.",
            );
            break :blk stringList(ctx.heap, try strings.split(gpa, bytes, separator));
        },
        .partition => blk: {
            const separator = arguments[0].data.string.bytes;
            if (separator.len == 0) return ctx.raise(
                "`partition` needs a separator, but this is an empty String",
                "Pass the text to find as the separator.",
            );
            const parts = try strings.partition(gpa, bytes, separator);
            break :blk stringTuple(ctx.heap, parts);
        },
        .lines => stringList(ctx.heap, try strings.lines(gpa, bytes)),
        .words => stringList(ctx.heap, try strings.words(gpa, bytes)),
        .chars => blk: {
            const pieces = try strings.characters(gpa, bytes);
            defer gpa.free(pieces);
            const list = try ctx.heap.createList(.string, pieces.len);
            const result: Value = .{ .data = .{ .list = list } };
            errdefer ctx.heap.release(result);
            for (pieces) |piece| list.items.appendAssumeCapacity(try ctx.heap.copyText(piece));
            break :blk result;
        },
        // These deliberately expose the exact stored representation rather
        // than graphemes. `chars()` remains the beginner-facing operation.
        .code_points => stringCodePoints(ctx.heap, bytes),
        .bytes => stringBytes(ctx.heap, bytes),
        // Section 9.2: the answer counts characters, so it indexes directly.
        .index_of => blk: {
            const found = try strings.indexOf(gpa, bytes, arguments[0].data.string.bytes);
            break :blk if (found) |index| Value.initInt(index) else Value.nothing;
        },
        // Section 4.4's three forms differ only in what they do when the text
        // does not parse: raise, use the fallback, or report absence.
        .to_int => blk: {
            const parsed = strings.parseInt(bytes);
            if (parsed == .value) break :blk .initInt(parsed.value);
            break :blk raiseConversion(ctx, bytes, "Int", parsed == .out_of_range);
        },
        .to_int_or => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else arguments[0];
        },
        .to_int_maybe => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else Value.nothing;
        },
        .to_float => blk: {
            const parsed = strings.parseFloat(bytes);
            if (parsed == .value) break :blk .initFloat(parsed.value);
            break :blk raiseConversion(ctx, bytes, "Float", parsed == .out_of_range);
        },
        .to_float_or => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else widen(arguments[0], .float);
        },
        .to_float_maybe => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else Value.nothing;
        },
    };
}

/// A three-part String tuple. The pieces borrow their receiver until copied.
pub fn stringTuple(heap: *Heap, parts: struct { []const u8, []const u8, []const u8 }) Error!Value {
    const items = try heap.gpa.alloc(Value, 3);
    const kinds = heap.gpa.alloc(Value.Kind, 3) catch |err| {
        heap.gpa.free(items);
        return err;
    };
    kinds[0] = .string;
    kinds[1] = .string;
    kinds[2] = .string;
    var built: usize = 0;
    var owned = true;
    errdefer if (owned) {
        for (items[0..built]) |item| heap.release(item);
        heap.gpa.free(items);
        heap.gpa.free(kinds);
    };
    inline for (parts) |part| {
        items[built] = try heap.copyText(part);
        built += 1;
    }
    // `createTuple` takes everything over, even when it fails.
    owned = false;
    return .{ .data = .{ .tuple = try heap.createTuple(items, kinds) } };
}

/// A list of strings from pieces the caller allocated, which the strings take.
pub fn stringList(heap: *Heap, pieces: [][]u8) Error!Value {
    defer heap.gpa.free(pieces);
    var taken: usize = 0;
    errdefer for (pieces[taken..]) |piece| heap.gpa.free(piece);

    const list = try heap.createList(.string, pieces.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);
    for (pieces) |piece| {
        taken += 1;
        list.items.appendAssumeCapacity(.{ .data = .{ .string = try heap.createText(piece) } });
    }
    return result;
}

/// Section 9.1's advanced conversions. A String is always valid UTF-8, so
/// each call to `unicode.decode` is safe. Code points retain the original
/// spelling: a decomposed character therefore gives its separate scalars.
pub fn stringCodePoints(heap: *Heap, bytes: []const u8) Error!Value {
    const list = try heap.createList(.int, bytes.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);

    var index: usize = 0;
    while (index < bytes.len) {
        const point, const length = unicode.decode(bytes, index);
        list.items.appendAssumeCapacity(.initInt(point));
        index += length;
    }
    return result;
}

/// UTF-8 bytes are represented as non-negative Ints until Emerald gains a
/// purpose-built binary-data type. This keeps `bytes()` honest without making
/// beginners learn an implementation-only `Byte` type.
pub fn stringBytes(heap: *Heap, bytes: []const u8) Error!Value {
    const list = try heap.createList(.int, bytes.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer heap.release(result);
    for (bytes) |byte| list.items.appendAssumeCapacity(.initInt(byte));
    return result;
}

/// Section 9.4's strict parsing, which raises a conversion error. Catching it
/// arrives with section 13; until then `to_int_or` is the way to recover.
pub fn raiseConversion(ctx: *Context, bytes: []const u8, comptime type_name: []const u8, out_of_range: bool) Error {
    const excerpt = if (bytes.len > 40) "the text" else try std.fmt.allocPrint(ctx.arena, "\"{s}\"", .{bytes});
    if (out_of_range) return ctx.raiseFmt(
        "{s} is outside the range of " ++ type_name,
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807. `to_int_or(0)` gives a fallback instead of an error."
        else
            "The number is too large for a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
    return ctx.raiseFmt(
        "{s} is not " ++ (if (std.mem.eql(u8, type_name, "Int")) "a whole number" else "a number"),
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "Only digits, with an optional sign and surrounding spaces, convert to an Int. `to_int_or(0)` gives a fallback instead of an error."
        else
            "Only a number such as `2.5` or `3`, with an optional sign and surrounding spaces, converts to a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
}

/// Section 9.1: substring bounds are errors rather than being clamped.
pub fn raiseSubstring(ctx: *Context, bytes: []const u8, start: i64, count: ?i64, err: strings.SubstringError) Error {
    const total = unicode.graphemeCount(bytes);
    return switch (err) {
        error.NegativeStart => ctx.raiseFmt("a substring cannot start at {d}", .{start}, "Start at 0 or later."),
        error.NegativeCount => ctx.raiseFmt("a substring cannot have {d} characters", .{count.?}, "Ask for 0 or more characters."),
        error.StartPastEnd => ctx.raiseFmt(
            "a substring cannot start at {d} in a String of {d} character{s}",
            .{ start, total, if (total == 1) "" else "s" },
            "Start at most at the String's `count`, which gives an empty String.",
        ),
        error.CountPastEnd => ctx.raiseFmt(
            "a substring of {d} character{s} from {d} runs past the end of a String of {d}",
            .{ count.?, if (count.? == 1) "" else "s", start, total },
            "Ask for fewer characters, or leave the count out to take the rest of the String.",
        ),
    };
}

pub fn raiseInsert(ctx: *Context, bytes: []const u8, index: i64, err: strings.InsertError) Error {
    const total = unicode.graphemeCount(bytes);
    return switch (err) {
        error.NegativeIndex => ctx.raiseFmt("a String insertion cannot use index {d}", .{index}, "Insert at 0 or later."),
        error.IndexPastEnd => ctx.raiseFmt(
            "cannot insert at index {d} in a String of {d} character{s}",
            .{ index, total, if (total == 1) "" else "s" },
            "Insert at 0 through the String's `count`; inserting at `count` adds to the end.",
        ),
    };
}

pub fn raisePadding(ctx: *Context, width: i64, fill: []const u8, err: strings.PadError) Error {
    return switch (err) {
        error.NegativeWidth => ctx.raiseFmt("a padded String cannot have width {d}", .{width}, "Choose a width of 0 or more characters."),
        error.EmptyFill => ctx.raise("padding needs a fill character, but this is an empty String", "Pass one character, such as `\"-\"` or `\" \"`."),
        error.MultipleCharacterFill => ctx.raiseFmt("padding needs one fill character, but \"{s}\" has {d}", .{ fill, unicode.graphemeCount(fill) }, "Pass exactly one character, such as `\"-\"` or `\" \"`."),
    };
}
