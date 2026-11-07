//! Section 15.9's JSON natives (`Native.zig`) for the prelude's `Json` value:
//! building one from parsed JSON, writing one as text, and key paths. Decoding
//! into a type the checker named stays with the engine, which knows the type.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const Json = @import("Json.zig");
const MapMethods = @import("MapMethods.zig");
const unicode = @import("unicode.zig");

const Context = Native.Context;
const Error = Native.Error;

/// Where each of the prelude `Json` struct's fields is.
pub const JsonFields = struct {
    kind: usize,
    bool: usize,
    number: usize,
    whole: usize,
    int: usize,
    decimal: usize,
    text: usize,
    items: usize,
    entries: usize,
    path: usize,

    pub fn of(descriptor: *const Value.StructType) JsonFields {
        return .{
            .kind = descriptor.fieldPosition("kind").?,
            .bool = descriptor.fieldPosition("_bool").?,
            .number = descriptor.fieldPosition("_number").?,
            .whole = descriptor.fieldPosition("_whole").?,
            .int = descriptor.fieldPosition("_int").?,
            .decimal = descriptor.fieldPosition("_decimal").?,
            .text = descriptor.fieldPosition("_text").?,
            .items = descriptor.fieldPosition("_items").?,
            .entries = descriptor.fieldPosition("_entries").?,
            .path = descriptor.fieldPosition("_path").?,
        };
    }
};

pub fn jsonFromValue(arena: std.mem.Allocator, at: JsonFields, value: Value) std.mem.Allocator.Error!Json.Value {
    const fields = value.data.struct_value.fields;
    const kind: Json.Kind = @fromBackingInt(@intCast(fields[at.kind].data.struct_value.variant));
    return switch (kind) {
        .null => .initNull(),
        .bool => .initBool(fields[at.bool].data.bool),
        .number => .{
            .kind = .number,
            .is_integer = fields[at.whole].data.bool,
            .int_value = fields[at.int].data.int,
            .float_value = fields[at.number].data.float,
            .is_float_literal = fields[at.decimal].data.bool,
        },
        .string => .initString(fields[at.text].data.string.bytes),
        .list => blk: {
            const source = fields[at.items].data.list.items.items;
            const items = try arena.alloc(Json.Value, source.len);
            for (source, items) |item, *json| json.* = try jsonFromValue(arena, at, item);
            break :blk .initList(items);
        },
        .object => blk: {
            const source = fields[at.entries].data.map.entries.items;
            const entries = try arena.alloc(Json.Entry, source.len);
            for (source, entries) |entry, *json| json.* = .{
                .key = entry.key.data.string.bytes,
                .value = try jsonFromValue(arena, at, entry.value),
            };
            break :blk .initObject(entries);
        },
    };
}

pub fn readsAsName(text: []const u8) bool {
    if (text.len == 0) return false;
    var index: usize = 0;
    while (index < text.len) {
        const code_point, const length = unicode.decode(text, index);
        const allowed = if (index == 0) unicode.isIdentifierStart(code_point) or code_point == '_' else unicode.isIdentifierContinue(code_point);
        if (!allowed) return false;
        index += length;
    }
    return true;
}

/// Builds a parsed document's tree of prelude `Json` values. A document can
/// hold many thousands of values, so every one that needs an empty text,
/// list, or dictionary shares the same one, and each kind's enum value is
/// built once.
/// A prelude `Json` value for parsed JSON.
pub fn buildValue(ctx: *Context, json: Json.Value) Error!Value {
    var builder = try JsonBuilder.init(ctx);
    defer builder.deinit();
    return builder.build(json);
}

/// Builds prelude `Json` values, sharing the kinds and empty collections
/// every value of one document needs. It holds `ctx`, so it lives only as
/// long as one native call.
const JsonBuilder = struct {
    ctx: *Context,
    descriptor: *const Value.StructType,
    fields: JsonFields,
    kinds: [std.meta.fieldNames(Json.Kind).len]Value,
    empty_text: Value,
    empty_items: Value,
    empty_entries: Value,

    fn init(ctx: *Context) Error!JsonBuilder {
        const heap = ctx.heap;
        const descriptor = ctx.preludeStruct("Json");
        const kind_descriptor = ctx.preludeStruct("Json::Kind");
        var builder: JsonBuilder = .{
            .ctx = ctx,
            .descriptor = descriptor,
            .fields = .of(descriptor),
            .kinds = @splat(Value.nothing),
            .empty_text = Value.nothing,
            .empty_items = Value.nothing,
            .empty_entries = Value.nothing,
        };
        errdefer builder.deinit();
        for (&builder.kinds, 0..) |*kind, index| {
            const instance = try heap.createStruct(kind_descriptor, &.{});
            instance.variant = @intCast(index);
            kind.* = .{ .data = .{ .struct_value = instance } };
        }
        builder.empty_text = try heap.copyText("");
        // Through locals: `builder.empty_items = .{ .data = .{ .list = try ... } }`
        // would write the `.list` tag before the `try`, so a failure would leave
        // `deinit` releasing an undefined pointer.
        const empty_items = try heap.createList(.struct_value, 0);
        builder.empty_items = .{ .data = .{ .list = empty_items } };
        const empty_entries = try heap.createMap(.string, .struct_value, false);
        builder.empty_entries = .{ .data = .{ .map = empty_entries } };
        return builder;
    }

    pub fn deinit(self: *JsonBuilder) void {
        const heap = self.ctx.heap;
        for (self.kinds) |kind| heap.release(kind);
        heap.release(self.empty_text);
        heap.release(self.empty_items);
        heap.release(self.empty_entries);
    }

    pub fn build(self: *JsonBuilder, json: Json.Value) Error!Value {
        const ctx = self.ctx;
        const heap = ctx.heap;
        const fields = try ctx.gpa.alloc(Value, self.descriptor.fields.len);
        @memset(fields, Value.nothing);
        var owned = true;
        errdefer if (owned) {
            for (fields) |field| heap.release(field);
            ctx.gpa.free(fields);
        };
        const at = self.fields;
        fields[at.kind] = Heap.retain(self.kinds[@backingInt(json.kind)]);
        fields[at.bool] = .initBool(json.bool_value);
        fields[at.number] = .initFloat(json.float_value);
        fields[at.whole] = .initBool(json.is_integer);
        fields[at.int] = .initInt(json.int_value);
        fields[at.decimal] = .initBool(json.is_float_literal);
        fields[at.path] = Heap.retain(self.empty_text);
        fields[at.text] = if (json.kind == .string) try heap.copyText(json.string_value) else Heap.retain(self.empty_text);

        if (json.kind == .list and json.items.len > 0) {
            const list = try heap.createList(.struct_value, json.items.len);
            fields[at.items] = .{ .data = .{ .list = list } };
            for (json.items) |item| list.items.appendAssumeCapacity(try self.build(item));
        } else {
            fields[at.items] = Heap.retain(self.empty_items);
        }

        if (json.kind == .object and json.entries.len > 0) {
            const map = try heap.createMap(.string, .struct_value, false);
            fields[at.entries] = .{ .data = .{ .map = map } };
            for (json.entries) |entry| {
                const key = try heap.copyText(entry.key);
                const hash = MapMethods.hashKey(ctx, key) catch |err| {
                    heap.release(key);
                    return err;
                };
                const value = self.build(entry.value) catch |err| {
                    heap.release(key);
                    return err;
                };
                // `Json.parse` has already refused duplicates, compared as
                // this dictionary compares its keys, so each one is new.
                try heap.put(map, hash, key, value, ctx.equatable());
            }
        } else {
            fields[at.entries] = Heap.retain(self.empty_entries);
        }

        owned = false;
        return .{ .data = .{ .struct_value = try heap.createStruct(self.descriptor, fields) } };
    }
};

/// A prelude `Json` value as JSON text.
pub fn jsonWrite(ctx: *Context, value: Value, pretty: bool) Error!Value {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const descriptor = ctx.preludeStruct("Json");
    const json = try jsonFromValue(arena_state.allocator(), JsonFields.of(descriptor), value);
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    Json.write(json, .{ .pretty = pretty }, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        // `Json.from_float` refuses these before a value is built. Keep the
        // native boundary safe too: a malformed internal Json value must still
        // be a normal, catchable JsonError rather than an interpreter crash.
        error.NonFiniteNumber => return raiseJson(ctx, "a non-finite Float cannot be written as JSON"),
    };
    return try ctx.heap.copyText(out.written());
}

/// The path to `key` inside the value at `path`, for messages: `.name` after
/// a path, `name` at the start of one, or `["first name"]` when the key does
/// not read as a name.
pub fn jsonKeyPath(ctx: *Context, path: []const u8, key: []const u8) Error!Value {
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    const writer = &out.writer;
    writer.writeAll(path) catch return error.OutOfMemory;
    if (readsAsName(key)) {
        if (path.len > 0) writer.writeByte('.') catch return error.OutOfMemory;
        writer.writeAll(key) catch return error.OutOfMemory;
    } else {
        writer.writeByte('[') catch return error.OutOfMemory;
        Json.write(.initString(key), .{}, writer) catch return error.OutOfMemory;
        writer.writeByte(']') catch return error.OutOfMemory;
    }
    return try ctx.heap.copyText(out.written());
}

pub fn raiseJson(ctx: *Context, message: []const u8) Error {
    return ctx.raiseTyped("JsonError", message, "JSON cannot represent NaN or infinity.");
}
