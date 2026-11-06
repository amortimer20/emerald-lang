//! A stub runtime for the compiler spike (not for merge). It stands in for the
//! shared runtime of the compiler plan's decision 4: reference-counted objects
//! with copy-on-write, a tagged value for erased positions, and natives with a
//! C ABI. Generated C calls the exported functions; generated Zig imports this
//! file and calls the same functions directly.

const std = @import("std");
const builtin = @import("builtin");
const FloatMath = @import("FloatMath.zig");

/// On a board with no operating system (the Pico question), a fixed heap and
/// an output hook the board code provides; elsewhere libc.
const freestanding = builtin.os.tag == .freestanding;
var heap_buffer: [if (freestanding) 96 * 1024 else 0]u8 = undefined;
var fixed = std.heap.FixedBufferAllocator.init(&heap_buffer);
inline fn gpa() std.mem.Allocator {
    return if (freestanding) fixed.allocator() else std.heap.c_allocator;
}

// ---------------------------------------------------------------- values

pub const Tag = enum(u8) { nothing, int, float, boolean, string, list, structure, dict };

/// A value in an erased position (a list element, a dictionary entry).
pub const Value = extern struct {
    tag: Tag,
    bits: u64,

    pub fn int(v: i64) Value {
        return .{ .tag = .int, .bits = @bitCast(v) };
    }
    pub fn float(v: f64) Value {
        return .{ .tag = .float, .bits = @bitCast(v) };
    }
    pub fn object(tag: Tag, pointer: anytype) Value {
        return .{ .tag = tag, .bits = @intFromPtr(pointer) };
    }
    pub fn asInt(self: Value) i64 {
        return @bitCast(self.bits);
    }
    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.bits);
    }
    pub fn ptr(self: Value, comptime T: type) *T {
        return @ptrFromInt(@as(usize, @intCast(self.bits)));
    }
};

/// The first field of every heap object.
pub const Header = extern struct { count: u32 = 1, tag: Tag };

pub const Str = extern struct {
    header: Header = .{ .tag = .string },
    len: usize,
    bytes: [*]u8,

    pub fn slice(self: *const Str) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const List = extern struct {
    header: Header = .{ .tag = .list },
    len: usize = 0,
    cap: usize = 0,
    items: [*]Value = undefined,

    pub fn slice(self: *List) []Value {
        return self.items[0..self.len];
    }
};

pub const Struct = extern struct {
    header: Header = .{ .tag = .structure },
    len: usize,
    fields: [*]Value,
};

const Map = std.ArrayHashMapUnmanaged(Value, Value, MapContext, true);

pub const Dict = struct {
    header: Header = .{ .tag = .dict },
    map: Map = .empty,
};

const MapContext = struct {
    pub fn hash(_: MapContext, key: Value) u32 {
        return switch (key.tag) {
            .string => @truncate(std.hash.Wyhash.hash(0, key.ptr(Str).slice())),
            else => @truncate(std.hash.Wyhash.hash(1, std.mem.asBytes(&key.bits))),
        };
    }
    pub fn eql(_: MapContext, a: Value, b: Value, _: usize) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .string => std.mem.eql(u8, a.ptr(Str).slice(), b.ptr(Str).slice()),
            else => a.bits == b.bits,
        };
    }
};

fn oom() noreturn {
    if (freestanding) @panic("out of memory");
    std.process.fatal("out of memory", .{});
}

pub export fn em_retain(value: Value) void {
    switch (value.tag) {
        .string, .list, .structure, .dict => value.ptr(Header).count += 1,
        else => {},
    }
}

pub export fn em_release(value: Value) void {
    switch (value.tag) {
        .string, .list, .structure, .dict => {},
        else => return,
    }
    const header = value.ptr(Header);
    header.count -= 1;
    if (header.count != 0) return;
    switch (value.tag) {
        .string => {
            const s = value.ptr(Str);
            gpa().free(s.bytes[0..s.len]);
            gpa().destroy(s);
        },
        .list => {
            const l = value.ptr(List);
            for (l.slice()) |item| em_release(item);
            if (l.cap != 0) gpa().free(l.items[0..l.cap]);
            gpa().destroy(l);
        },
        .structure => {
            const s = value.ptr(Struct);
            for (s.fields[0..s.len]) |item| em_release(item);
            gpa().free(s.fields[0..s.len]);
            gpa().destroy(s);
        },
        .dict => {
            const d = value.ptr(Dict);
            var it = d.map.iterator();
            while (it.next()) |entry| {
                em_release(entry.key_ptr.*);
                em_release(entry.value_ptr.*);
            }
            d.map.deinit(gpa());
            gpa().destroy(d);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- errors

var error_message: [256]u8 = undefined;
var error_len: usize = 0;
var error_line: c_int = 0;

/// Records a runtime error; generated code then returns a nonzero status up
/// to `main`, releasing what it holds on the way.
pub export fn em_fail(message: [*:0]const u8, line: c_int) c_int {
    const text = std.mem.span(message);
    error_len = @min(text.len, error_message.len);
    @memcpy(error_message[0..error_len], text[0..error_len]);
    error_line = line;
    return 1;
}

pub export fn em_fail_overflow(line: c_int) c_int {
    return em_fail("Int arithmetic overflowed", line);
}

/// Prints the recorded error and gives the exit code.
pub export fn em_report() c_int {
    em_flush();
    var buffer: [320]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "error: {s}\n  at line {d}\n", .{ error_message[0..error_len], error_line }) catch unreachable;
    writeFd(2, text);
    return 1;
}

// ---------------------------------------------------------------- output

var out_buffer: [1 << 16]u8 = undefined;
var out_len: usize = 0;

const c = struct {
    extern "c" fn _write(fd: c_int, buffer: [*]const u8, count: c_uint) c_int;
    extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
};

extern fn em_board_write(fd: c_int, bytes: [*]const u8, len: usize) void;

fn writeFd(fd: c_int, bytes: []const u8) void {
    if (freestanding) {
        em_board_write(fd, bytes.ptr, bytes.len);
    } else if (builtin.os.tag == .windows) {
        _ = c._write(fd, bytes.ptr, @intCast(bytes.len));
    } else {
        _ = c.write(fd, bytes.ptr, bytes.len);
    }
}

fn out(bytes: []const u8) void {
    if (out_len + bytes.len > out_buffer.len) em_flush();
    if (bytes.len > out_buffer.len) return writeFd(1, bytes);
    @memcpy(out_buffer[out_len..][0..bytes.len], bytes);
    out_len += bytes.len;
}

pub export fn em_flush() void {
    if (out_len != 0) writeFd(1, out_buffer[0..out_len]);
    out_len = 0;
}

pub export fn em_out_int(value: i64) void {
    var buffer: [24]u8 = undefined;
    out(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
}

pub export fn em_out_float(value: f64) void {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    out(text);
    if (std.mem.indexOfScalar(u8, text, '.') == null) out(".0");
}

pub export fn em_out_str(s: *Str) void {
    out(s.slice());
}

pub export fn em_out_sep() void {
    out(" ");
}

pub export fn em_out_newline() void {
    out("\n");
}

// ---------------------------------------------------------------- floats

pub export fn em_float_round_to(value: f64, places: i64) f64 {
    return FloatMath.roundTo(value, places);
}

// ---------------------------------------------------------------- strings

pub export fn em_str_new(bytes: [*]const u8, len: usize) *Str {
    const copy = gpa().alloc(u8, len) catch oom();
    @memcpy(copy, bytes[0..len]);
    const s = gpa().create(Str) catch oom();
    s.* = .{ .len = len, .bytes = copy.ptr };
    return s;
}

fn strOwned(bytes: []u8) *Str {
    const s = gpa().create(Str) catch oom();
    s.* = .{ .len = bytes.len, .bytes = bytes.ptr };
    return s;
}

/// `list.join(separator)` for a list of strings.
pub export fn em_list_join(list: *List, separator: *Str) *Str {
    var total: usize = 0;
    for (list.slice(), 0..) |item, i| {
        total += item.ptr(Str).len;
        if (i != 0) total += separator.len;
    }
    const bytes = gpa().alloc(u8, total) catch oom();
    var at: usize = 0;
    for (list.slice(), 0..) |item, i| {
        if (i != 0) {
            @memcpy(bytes[at..][0..separator.len], separator.slice());
            at += separator.len;
        }
        const piece = item.ptr(Str).slice();
        @memcpy(bytes[at..][0..piece.len], piece);
        at += piece.len;
    }
    return strOwned(bytes);
}

/// `text.words()`: the pieces between runs of whitespace (ASCII only here).
pub export fn em_str_words(s: *Str) *List {
    const list = em_list_new();
    var it = std.mem.tokenizeAny(u8, s.slice(), " \t\r\n");
    while (it.next()) |word| em_list_push(list, Value.object(.string, em_str_new(word.ptr, word.len)));
    return list;
}

// ---------------------------------------------------------------- lists

pub export fn em_list_new() *List {
    const l = gpa().create(List) catch oom();
    l.* = .{};
    return l;
}

/// Appends to a list the caller already owns uniquely, taking the value.
fn em_list_push(l: *List, value: Value) void {
    if (l.len == l.cap) {
        const cap = @max(8, l.cap * 2);
        const items = if (l.cap == 0)
            gpa().alloc(Value, cap) catch oom()
        else
            gpa().realloc(l.items[0..l.cap], cap) catch oom();
        l.items = items.ptr;
        l.cap = cap;
    }
    l.items[l.len] = value;
    l.len += 1;
}

/// Makes the list in `slot` uniquely owned, copying it if it is shared
/// (section 8.1's copy-on-write).
pub export fn em_list_unique(slot: **List) *List {
    const l = slot.*;
    if (l.header.count == 1) return l;
    const copy = em_list_new();
    for (l.slice()) |item| {
        em_retain(item);
        em_list_push(copy, item);
    }
    l.header.count -= 1;
    slot.* = copy;
    return copy;
}

/// `list.append(value)`, taking the value.
pub export fn em_list_append(slot: **List, value: Value) void {
    em_list_push(em_list_unique(slot), value);
}

pub export fn em_list_count(l: *List) i64 {
    return @intCast(l.len);
}

/// `list[index]`, borrowed: the caller retains it if it keeps it.
pub export fn em_list_get(l: *List, index: i64, result: *Value, line: c_int) c_int {
    if (index < 0 or index >= l.len) return em_fail("index out of range", line);
    result.* = l.items[@intCast(index)];
    return 0;
}

/// A uniquely owned struct at `list[index]`, for a field write through the
/// list (`bodies[i].vx += ...`): the list and the struct are both made unique.
pub export fn em_list_struct_for_write(slot: **List, index: i64, result: **Struct, line: c_int) c_int {
    const l = em_list_unique(slot);
    if (index < 0 or index >= l.len) return em_fail("index out of range", line);
    const item = &l.items[@intCast(index)];
    result.* = em_struct_unique(item);
    return 0;
}

// ---------------------------------------------------------------- structs

pub export fn em_struct_new(len: usize, fields: [*]const Value) *Struct {
    const copy = gpa().alloc(Value, len) catch oom();
    @memcpy(copy, fields[0..len]);
    const s = gpa().create(Struct) catch oom();
    s.* = .{ .len = len, .fields = copy.ptr };
    return s;
}

pub export fn em_struct_unique(slot: *Value) *Struct {
    const s = slot.ptr(Struct);
    if (s.header.count == 1) return s;
    for (s.fields[0..s.len]) |field| em_retain(field);
    const copy = em_struct_new(s.len, s.fields);
    s.header.count -= 1;
    slot.* = Value.object(.structure, copy);
    return copy;
}

// ---------------------------------------------------------------- dictionaries

pub export fn em_dict_new() *Dict {
    const d = gpa().create(Dict) catch oom();
    d.* = .{};
    return d;
}

/// `dict[key]`, borrowed, or false when it is absent.
pub export fn em_dict_get(d: *Dict, key: Value, result: *Value) bool {
    result.* = d.map.get(key) orelse return false;
    return true;
}

fn dictUnique(slot: **Dict) *Dict {
    const d = slot.*;
    if (d.header.count == 1) return d;
    const copy = em_dict_new();
    copy.map = d.map.clone(gpa()) catch oom();
    for (copy.map.keys(), copy.map.values()) |k, v| {
        em_retain(k);
        em_retain(v);
    }
    d.header.count -= 1;
    slot.* = copy;
    return copy;
}

/// `dict[key] = value`, taking both.
pub export fn em_dict_set(slot: **Dict, key: Value, value: Value) void {
    const d = dictUnique(slot);
    const entry = d.map.getOrPut(gpa(), key) catch oom();
    if (entry.found_existing) {
        em_release(key);
        em_release(entry.value_ptr.*);
    }
    entry.value_ptr.* = value;
}

pub export fn em_dict_count(d: *Dict) i64 {
    return @intCast(d.map.count());
}

/// `dict.entries()`: a list of (key, value) tuples, in insertion order.
pub export fn em_dict_entries(d: *Dict) *List {
    const list = em_list_new();
    for (d.map.keys(), d.map.values()) |k, v| {
        em_retain(k);
        em_retain(v);
        const pair = [2]Value{ k, v };
        em_list_push(list, Value.object(.structure, em_struct_new(2, &pair)));
    }
    return list;
}

// ---------------------------------------------------------------- closures and sorting

/// A key function from generated code: an environment and a C function.
pub const KeyFn = *const fn (env: ?*anyopaque, item: Value, result: *Value) callconv(.c) c_int;

/// `list.sort_by { ... }`: a new list ordered by the keys (Int keys here),
/// stable, so equal keys keep their order.
pub export fn em_list_sort_by(l: *List, key: KeyFn, env: ?*anyopaque, result: **List) c_int {
    const Keyed = struct { key: i64, value: Value };
    const keyed = gpa().alloc(Keyed, l.len) catch oom();
    defer gpa().free(keyed);
    for (l.slice(), keyed) |item, *k| {
        var key_value: Value = undefined;
        const status = key(env, item, &key_value);
        if (status != 0) return status;
        k.* = .{ .key = key_value.asInt(), .value = item };
    }
    std.sort.block(Keyed, keyed, {}, struct {
        fn less(_: void, a: Keyed, b: Keyed) bool {
            return a.key < b.key;
        }
    }.less);
    const sorted = em_list_new();
    for (keyed) |k| {
        em_retain(k.value);
        em_list_push(sorted, k.value);
    }
    result.* = sorted;
    return 0;
}

// ---------------------------------------------------------------- Random

/// `Random(seed).next(first..<end)`, the interpreter's algorithm: a fresh
/// generator from the state, one draw, and the next state.
pub export fn em_random_next(state: *i64, first: i64, end: i64) i64 {
    var engine = std.Random.DefaultPrng.init(@bitCast(state.*));
    const source = engine.random();
    const length: u64 = @intCast(end - first);
    const position = source.uintLessThan(u64, length);
    state.* = @bitCast(source.int(u64));
    return first + @as(i64, @intCast(position));
}
