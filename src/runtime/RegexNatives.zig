//! Section 15.4's regular-expression natives (`Native.zig`), which the
//! prelude's `Regex` calls with the pattern and its options first. Matching is
//! Emerald's own engine (`Regex.zig`); this file turns its results into values.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const Regex = @import("Regex.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;

const regex_cache_limit = 256;

/// Section 15.4's natives, which the prelude's `Regex` calls with the pattern
/// and its options first.
pub const Method = enum { escape, _problem, @"_whole?", _find, _replace, _split, _splice };

pub fn call(ctx: *Context, native: Method, values: []const Value) Error!Value {
    switch (native) {
        .escape => return try regexEscape(ctx, values[0].data.string.bytes),
        ._problem => return try regexProblem(ctx, values),
        .@"_whole?", ._find, ._replace, ._split => {
            var compiled = try regexFor(ctx, values);
            defer compiled.deinit();
            const text = try Regex.Text.init(ctx.gpa, values[3].data.string.bytes);
            defer text.deinit(ctx.gpa);
            const slots = try ctx.gpa.alloc(usize, compiled.program.slotCount());
            defer ctx.gpa.free(slots);
            var matcher = try Regex.Matcher.init(ctx.gpa, &compiled.program);
            defer matcher.deinit();
            var matches: RegexMatches = .{ .matcher = &matcher, .text = text, .slots = slots };
            return switch (native) {
                .@"_whole?" => .initBool(try matcher.run(text, 0, .whole, slots)),
                ._find => try regexFind(ctx, &matches, values[0], @intCast(values[4].data.int)),
                ._replace => try regexReplace(ctx, &matches, values[4].data.string.bytes, @intCast(values[5].data.int)),
                ._split => try regexSplit(ctx, &matches),
                else => unreachable,
            };
        },
        ._splice => {
            const text = try Regex.Text.init(ctx.gpa, values[0].data.string.bytes);
            defer text.deinit(ctx.gpa);
            return try regexSplice(ctx, text, values[1].data.list.items.items, values[2].data.list.items.items);
        },
    }
}

/// A compiled pattern, which the caller deinitializes only when `owned`: one
/// from the cache belongs to the execution.
const CompiledRegex = struct {
    program: Regex.Program,
    owned: bool,

    fn deinit(self: *CompiledRegex) void {
        if (self.owned) self.program.deinit();
    }
};

pub fn regexOptions(values: []const Value) Regex.Options {
    return .{ .ignore_case = values[1].data.bool, .multiline = values[2].data.bool };
}

pub fn compileRegex(ctx: *Context, pattern: []const u8, options: Regex.Options, problem: *Regex.Problem) Regex.CompileError!CompiledRegex {
    const key = try std.fmt.allocPrint(ctx.gpa, "{c}{c}{s}", .{
        @as(u8, if (options.ignore_case) 'i' else '-'),
        @as(u8, if (options.multiline) 'm' else '-'),
        pattern,
    });
    defer ctx.gpa.free(key);
    if (ctx.state.regex_cache.get(key)) |program| return .{ .program = program, .owned = false };
    if (ctx.state.regex_cache.count() >= regex_cache_limit) {
        return .{ .program = try Regex.compile(ctx.gpa, pattern, options, problem), .owned = true };
    }
    const program = try Regex.compile(ctx.arena, pattern, options, problem);
    try ctx.state.regex_cache.put(ctx.arena, try ctx.arena.dupe(u8, key), program);
    return .{ .program = program, .owned = false };
}

/// The program for a `Regex` value's pattern, which its constructor has
/// already compiled once, so it cannot be refused now.
pub fn regexFor(ctx: *Context, values: []const Value) Error!CompiledRegex {
    var problem: Regex.Problem = .{};
    return compileRegex(ctx, values[0].data.string.bytes, regexOptions(values), &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => unreachable,
    };
}

pub fn regexProblem(ctx: *Context, values: []const Value) Error!Value {
    const pattern = values[0].data.string.bytes;
    var problem: Regex.Problem = .{};
    var compiled = compileRegex(ctx, pattern, regexOptions(values), &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => {
            const message = try std.fmt.allocPrint(ctx.gpa, "the pattern \"{s}\" at position {d}: {s}", .{ pattern, problem.position, problem.message() });
            return .{ .data = .{ .string = try ctx.heap.createText(message) } };
        },
    };
    compiled.deinit();
    return .nothing;
}

/// Section 15.4's non-overlapping matches from left to right. After a match
/// of nothing the search moves on one character, and a match of nothing just
/// where the previous match ended does not count, as in Go and Rust: `x*`
/// finds three matches in "ab", and `\s*` two in "a b" besides the space.
const RegexMatches = struct {
    matcher: *Regex.Matcher,
    text: Regex.Text,
    /// The current match's groups, once `next` has returned true.
    slots: []usize,
    position: usize = 0,
    previous_end: ?usize = null,

    fn next(self: *RegexMatches) Error!bool {
        while (self.position <= self.text.count()) {
            if (!try self.matcher.run(self.text, self.position, .search, self.slots)) return false;
            const start = self.slots[0];
            const end = self.slots[1];
            if (start == end and self.previous_end == start) {
                self.position = start + 1;
                continue;
            }
            self.previous_end = end;
            self.position = if (start == end) end + 1 else end;
            return true;
        }
        return false;
    }
};

/// At most `limit` matches as `Regex.Match` values, or all of them for 0.
pub fn regexFind(ctx: *Context, matches: *RegexMatches, pattern: Value, limit: usize) Error!Value {
    const program = matches.matcher.program;
    const descriptor = ctx.preludeStruct("Regex::Match");
    var found: std.ArrayList(Value) = .empty;
    defer found.deinit(ctx.gpa);
    errdefer for (found.items) |value| ctx.heap.release(value);

    // Every match shares one list of the pattern's group names.
    const groups = @as(usize, program.group_count) + 1;
    const names_list = try ctx.heap.createList(.string, groups);
    const names: Value = .{ .data = .{ .list = names_list } };
    defer ctx.heap.release(names);
    for (0..groups) |group| {
        var name: []const u8 = "";
        for (program.names) |entry| {
            if (entry.number == group) name = entry.name;
        }
        names_list.items.appendAssumeCapacity(try ctx.heap.copyText(name));
    }

    while ((limit == 0 or found.items.len < limit) and try matches.next()) {
        try found.ensureUnusedCapacity(ctx.gpa, 1);
        found.appendAssumeCapacity(try regexMatch(ctx, descriptor, matches.text, matches.slots, names, pattern));
    }
    const list = try ctx.heap.createList(.struct_value, found.items.len);
    list.items.appendSliceAssumeCapacity(found.items);
    found.clearRetainingCapacity();
    return .{ .data = .{ .list = list } };
}

/// The text with at most `limit` matches (0 for all) replaced by
/// `replacement`, used as it is written.
pub fn regexReplace(ctx: *Context, matches: *RegexMatches, replacement: []const u8, limit: usize) Error!Value {
    const text = matches.text;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.gpa);
    var previous: usize = 0;
    var replaced: usize = 0;
    while ((limit == 0 or replaced < limit) and try matches.next()) : (replaced += 1) {
        try result.appendSlice(ctx.gpa, text.slice(previous, matches.slots[0]));
        try result.appendSlice(ctx.gpa, replacement);
        previous = matches.slots[1];
    }
    try result.appendSlice(ctx.gpa, text.slice(previous, text.count()));
    return .{ .data = .{ .string = try ctx.heap.createText(try result.toOwnedSlice(ctx.gpa)) } };
}

/// The pieces between matches, empty ones included. A match of nothing at
/// the very start or end splits nothing off, so a pattern that matches
/// nothing splits between every character.
pub fn regexSplit(ctx: *Context, matches: *RegexMatches) Error!Value {
    const text = matches.text;
    var pieces: std.ArrayList(Value) = .empty;
    defer pieces.deinit(ctx.gpa);
    errdefer for (pieces.items) |piece| ctx.heap.release(piece);
    var previous: usize = 0;
    while (try matches.next()) {
        const start = matches.slots[0];
        const end = matches.slots[1];
        if (start == end and (start == 0 or start == text.count())) continue;
        try pieces.ensureUnusedCapacity(ctx.gpa, 1);
        pieces.appendAssumeCapacity(try ctx.heap.copyText(text.slice(previous, start)));
        previous = end;
    }
    try pieces.ensureUnusedCapacity(ctx.gpa, 1);
    pieces.appendAssumeCapacity(try ctx.heap.copyText(text.slice(previous, text.count())));
    const list = try ctx.heap.createList(.string, pieces.items.len);
    list.items.appendSliceAssumeCapacity(pieces.items);
    pieces.clearRetainingCapacity();
    return .{ .data = .{ .list = list } };
}

/// A `Regex.Match` for the match `slots` describe.
pub fn regexMatch(ctx: *Context, descriptor: *const Value.StructType, text: Regex.Text, slots: []const usize, names: Value, pattern: Value) Error!Value {
    const fields = try ctx.gpa.alloc(Value, descriptor.fields.len);
    @memset(fields, Value.nothing);
    var owned = true;
    errdefer if (owned) {
        for (fields) |field| ctx.heap.release(field);
        ctx.gpa.free(fields);
    };
    const groups = slots.len / 2;
    const whole = try ctx.heap.copyText(text.slice(slots[0], slots[1]));
    fields[descriptor.fieldPosition("text").?] = whole;
    fields[descriptor.fieldPosition("start").?] = .initInt(@intCast(slots[0]));
    fields[descriptor.fieldPosition("end").?] = .initInt(@intCast(slots[1]));
    fields[descriptor.fieldPosition("_names").?] = Heap.retain(names);
    fields[descriptor.fieldPosition("_pattern").?] = Heap.retain(pattern);
    const spans = try ctx.heap.createList(.int, 2 * groups);
    fields[descriptor.fieldPosition("_spans").?] = .{ .data = .{ .list = spans } };
    const texts = try ctx.heap.createList(.string, groups);
    fields[descriptor.fieldPosition("_texts").?] = .{ .data = .{ .list = texts } };
    texts.items.appendAssumeCapacity(Heap.retain(whole));
    for (0..groups) |group| {
        const start = slots[2 * group];
        const end = slots[2 * group + 1];
        const took_part = start != Regex.unset and end != Regex.unset;
        spans.items.appendAssumeCapacity(.initInt(if (took_part) @intCast(start) else -1));
        spans.items.appendAssumeCapacity(.initInt(if (took_part) @intCast(end) else -1));
        if (group > 0) texts.items.appendAssumeCapacity(try ctx.heap.copyText(if (took_part) text.slice(start, end) else ""));
    }
    owned = false;
    return .{ .data = .{ .struct_value = try ctx.heap.createStruct(descriptor, fields) } };
}

pub fn matchBounds(found: Value) struct { usize, usize } {
    const object = found.data.struct_value;
    return .{
        @intCast(object.fields[object.descriptor.fieldPosition("start").?].data.int),
        @intCast(object.fields[object.descriptor.fieldPosition("end").?].data.int),
    };
}

/// `text` with each match, in order and not overlapping, replaced by the
/// replacement at the same position.
pub fn regexSplice(ctx: *Context, text: Regex.Text, found: []const Value, replacements: []const Value) Error!Value {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.gpa);
    var previous: usize = 0;
    for (found, replacements) |match, replacement| {
        const start, const end = matchBounds(match);
        try result.appendSlice(ctx.gpa, text.slice(previous, start));
        try result.appendSlice(ctx.gpa, replacement.data.string.bytes);
        previous = end;
    }
    try result.appendSlice(ctx.gpa, text.slice(previous, text.count()));
    return .{ .data = .{ .string = try ctx.heap.createText(try result.toOwnedSlice(ctx.gpa)) } };
}

/// Section 15.4's `Regex.escape`: a backslash before every character with a
/// meaning in patterns. A character that begins with one and carries more
/// code points, such as "." with a combining accent, is written as `\u{...}`
/// escapes instead, since a backslash applies to a single code point.
pub fn regexEscape(ctx: *Context, bytes: []const u8) Error!Value {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.gpa);
    var clusters: unicode.Graphemes = .init(bytes);
    while (clusters.next()) |cluster| {
        if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$-", cluster[0]) == null) {
            try result.appendSlice(ctx.gpa, cluster);
        } else if (cluster.len == 1) {
            try result.append(ctx.gpa, '\\');
            try result.append(ctx.gpa, cluster[0]);
        } else {
            var points = (std.unicode.Utf8View.init(cluster) catch unreachable).iterator();
            while (points.nextCodepoint()) |point| try result.print(ctx.gpa, "\\u{{{X}}}", .{point});
        }
    }
    return .{ .data = .{ .string = try ctx.heap.createText(try result.toOwnedSlice(ctx.gpa)) } };
}
