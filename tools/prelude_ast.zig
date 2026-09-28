//! Parses `src/prelude.em` when Emerald is built and writes its syntax tree as
//! Zig constant data, so a run starts with the prelude already parsed instead
//! of lexing and parsing it every time (the startup entries in docs/journal.md).
//!
//!   prelude-ast <prelude.em> <output.zig>
//!
//! The output is one generic declaration, `Prelude(Ast).program`, written
//! with anonymous literals (`.{ ... }`, `&.{ ... }`) so it needs no type names:
//! every value's type comes from where it goes. A pointer becomes `&.{ ... }`
//! and a slice `&.{ ... }` of its items, so the whole tree is static data.

const std = @import("std");
const front = @import("front");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: prelude-ast <prelude.em> <output.zig>\n", .{});
        return error.Usage;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(text);

    var source = try front.Source.init(gpa, "prelude.em", text);
    defer source.deinit(gpa);
    var tokenized = try front.Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    var parsed = try front.Parser.parse(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    for (tokenized.diagnostics) |diagnostic| report(source, diagnostic);
    for (parsed.diagnostics) |diagnostic| report(source, diagnostic);
    if (tokenized.diagnostics.len + parsed.diagnostics.len != 0) return error.PreludeDoesNotParse;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        \\//! Generated from src/prelude.em by tools/prelude_ast.zig when Emerald is
        \\//! built. Do not edit.
        \\
        \\pub fn Prelude(comptime Ast: type) type {
        \\    return struct {
        \\        pub const program: Ast.Program = 
    );
    try emit(writer, parsed.program);
    try writer.writeAll(";\n    };\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

fn report(source: front.Source, diagnostic: anytype) void {
    const at = source.location(diagnostic.span.start);
    std.debug.print("prelude.em:{d}:{d}: {s}\n", .{ at.line, at.column, diagnostic.message });
}

/// Writes `value` as a Zig literal whose type comes from where it is used.
fn emit(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int => try writer.print("{d}", .{value}),
        // Exact, whatever the value: its bits, not a decimal rendering.
        .float => try writer.print("@bitCast(@as(u{d}, 0x{x}))", .{ @bitSizeOf(T), @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value)) }),
        .@"enum" => try writer.print(".{f}", .{std.zig.fmtIdP(@tagName(value))}),
        .void => try writer.writeAll("{}"),
        .optional => if (value) |inner| try emit(writer, inner) else try writer.writeAll("null"),
        .pointer => |pointer| switch (pointer.size) {
            .one => {
                try writer.writeAll("&");
                try emit(writer, value.*);
            },
            .slice => {
                if (pointer.child == u8) {
                    try writer.print("\"{f}\"", .{std.zig.fmtString(value)});
                    return;
                }
                try writer.writeAll("&.{");
                for (value, 0..) |item, index| {
                    if (index > 0) try writer.writeAll(",");
                    try emit(writer, item);
                }
                try writer.writeAll("}");
            },
            else => @compileError("the prelude's syntax tree holds a pointer that is neither one item nor a slice: " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            try writer.writeAll(".{");
            inline for (info.fields, 0..) |field, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.print(".{f}=", .{std.zig.fmtIdP(field.name)});
                try emit(writer, @field(value, field.name));
            }
            try writer.writeAll("}");
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, @tagName(tag))) {
                    try writer.print(".{{.{f}=", .{std.zig.fmtIdP(field.name)});
                    try emit(writer, @field(value, field.name));
                    try writer.writeAll("}");
                    return;
                }
            }
            unreachable;
        },
        .array => {
            try writer.writeAll(".{");
            for (value, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try emit(writer, item);
            }
            try writer.writeAll("}");
        },
        else => @compileError("the prelude's syntax tree holds a value that cannot be written as a literal: " ++ @typeName(T)),
    }
}
