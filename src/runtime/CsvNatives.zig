//! Section 15.11's CSV natives (`Native.zig`): rows, records and text, and
//! the `CsvError` messages. Decoding into a type the checker named stays with
//! the engine, which knows the type.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const Csv = @import("Csv.zig");
const MapMethods = @import("MapMethods.zig");

const Context = Native.Context;
const Error = Native.Error;

pub fn csvRows(ctx: *Context, text: []const u8, separator: []const u8) Error!Value {
    var problem: Csv.Problem = .{};
    var document = Csv.parse(ctx.gpa, text, separator, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCsv => return raiseCsvProblem(ctx, problem),
    };
    defer document.deinit();

    const rows = try ctx.heap.createList(.list, document.rows.len);
    const result: Value = .{ .data = .{ .list = rows } };
    errdefer ctx.heap.release(result);
    for (document.rows) |row| {
        const fields = try ctx.heap.createList(.string, row.fields.len);
        const value: Value = .{ .data = .{ .list = fields } };
        errdefer ctx.heap.release(value);
        for (row.fields) |field| fields.items.appendAssumeCapacity(try ctx.heap.copyText(field));
        rows.items.appendAssumeCapacity(value);
    }
    return result;
}

pub fn csvRecords(ctx: *Context, text: []const u8, separator: []const u8) Error!Value {
    var problem: Csv.Problem = .{};
    var document = Csv.parse(ctx.gpa, text, separator, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCsv => return raiseCsvProblem(ctx, problem),
    };
    defer document.deinit();
    if (document.rows.len == 0) {
        return .{ .data = .{ .list = try ctx.heap.createList(.map, 0) } };
    }

    const header = document.rows[0];
    for (header.fields, 0..) |name, index| {
        if (name.len == 0) return raiseCsv(ctx, "the header has an empty column name", header.line);
        for (header.fields[0..index]) |earlier| {
            if (std.mem.eql(u8, name, earlier)) {
                const message = try std.fmt.allocPrint(ctx.arena, "the header names the column \"{s}\" twice", .{name});
                return raiseCsv(ctx, message, header.line);
            }
        }
    }

    const records = try ctx.heap.createList(.map, document.rows.len - 1);
    const result: Value = .{ .data = .{ .list = records } };
    errdefer ctx.heap.release(result);
    for (document.rows[1..]) |row| {
        if (row.fields.len != header.fields.len) {
            const message = try std.fmt.allocPrint(ctx.arena, "line {d} has {d} fields, but the header has {d}", .{ row.line, row.fields.len, header.fields.len });
            return raiseCsv(ctx, message, row.line);
        }
        const record = try ctx.heap.createMap(.string, .string, false);
        const value: Value = .{ .data = .{ .map = record } };
        errdefer ctx.heap.release(value);
        for (header.fields, row.fields) |name, field| {
            const key = try ctx.heap.copyText(name);
            const field_value = try ctx.heap.copyText(field);
            const hash = try MapMethods.hashKey(ctx, key);
            try ctx.heap.put(record, hash, key, field_value, ctx.equatable());
        }
        records.items.appendAssumeCapacity(value);
    }
    return result;
}

pub fn csvFormat(ctx: *Context, rows: *const Heap.List, separator: []const u8) Error!Value {
    const row_slices = try ctx.gpa.alloc([]const []const u8, rows.items.items.len);
    defer ctx.gpa.free(row_slices);
    var field_count: usize = 0;
    for (rows.items.items) |row| field_count += row.data.list.items.items.len;
    const fields = try ctx.gpa.alloc([]const u8, field_count);
    defer ctx.gpa.free(fields);
    var at: usize = 0;
    for (rows.items.items, row_slices) |row, *out| {
        const items = row.data.list.items.items;
        out.* = fields[at .. at + items.len];
        for (items) |item| {
            fields[at] = item.data.string.bytes;
            at += 1;
        }
    }
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    Csv.write(row_slices, separator, &out.writer) catch |err| switch (err) {
        error.InvalidSeparator => return raiseCsvSeparator(ctx, separator),
        error.WriteFailed => return error.OutOfMemory,
    };
    return .{ .data = .{ .string = try ctx.heap.createText(try out.toOwnedSlice()) } };
}

pub fn raiseCsv(ctx: *Context, message: []const u8, line: ?u32) Error {
    const value = try makeCsvError(ctx, message, line);
    return ctx.raiseValue("CsvError", value, message, "Correct the CSV text or use a one-character separator.");
}

pub fn makeCsvError(ctx: *Context, message: []const u8, line: ?u32) Error!Value {
    const descriptor = ctx.preludeStruct("CsvError");
    const fields = try ctx.gpa.alloc(Value, descriptor.fields.len);
    @memset(fields, Value.nothing);
    var owned = true;
    errdefer if (owned) {
        for (fields) |field| ctx.heap.release(field);
        ctx.gpa.free(fields);
    };
    for (descriptor.fields, fields) |field, *value| {
        if (std.mem.eql(u8, field.name, "message")) value.* = try ctx.heap.copyText(message);
        if (std.mem.eql(u8, field.name, "line")) value.* = if (line) |number| .initInt(number) else .nothing;
    }
    // `createStruct` takes the fields over, even when it fails.
    owned = false;
    return .{ .data = .{ .struct_value = try ctx.heap.createStruct(descriptor, fields) } };
}

pub fn raiseCsvProblem(ctx: *Context, problem: Csv.Problem) Error {
    const message = if (problem.line) |line|
        std.fmt.allocPrint(ctx.arena, "line {d}: {s}", .{ line, problem.message() }) catch return error.OutOfMemory
    else
        problem.message();
    return raiseCsv(ctx, message, problem.line);
}

pub fn raiseCsvSeparator(ctx: *Context, separator: []const u8) Error {
    const message = std.fmt.allocPrint(ctx.arena, "a separator must be one character, not \"{s}\"", .{separator}) catch return error.OutOfMemory;
    return raiseCsv(ctx, message, null);
}

pub fn raiseCsvCell(ctx: *Context, line: u32, column: []const u8, detail: []const u8) Error {
    const message = std.fmt.allocPrint(ctx.arena, "line {d}, column \"{s}\": {s}", .{ line, column, detail }) catch return error.OutOfMemory;
    return raiseCsv(ctx, message, line);
}
