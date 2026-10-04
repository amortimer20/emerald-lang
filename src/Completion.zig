//! Completion presentation, not typing rules or a second member inventory.
//! Native descriptions come from Builtins; declarations keep their source text.
const std = @import("std");
const emerald = @import("emerald");
const Type = emerald.Type;
const Builtins = emerald.Builtins;

pub const Item = struct {
    label: []const u8,
    kind: u8 = 6,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    insertTextFormat: u8 = 1,
    // Lexical origin is presentation input, never part of the LSP reply.
    declaration: ?emerald.Ast.Statement = null,
    parameter: ?emerald.Ast.Parameter = null,
    lambda_parameter: ?emerald.Ast.Expression.LambdaParameter = null,
    owned_label: bool = false,

    pub fn jsonStringify(self: Item, out: *std.json.Stringify) !void {
        try out.write(.{ .label = self.label, .kind = self.kind, .detail = self.detail, .documentation = self.documentation, .insertText = self.insertText, .insertTextFormat = self.insertTextFormat });
    }

    pub fn deinit(self: Item, gpa: std.mem.Allocator) void {
        if (self.owned_label) gpa.free(self.label);
        if (self.detail) |text| gpa.free(text);
        if (self.documentation) |text| gpa.free(text);
        if (self.insertText) |text| gpa.free(text);
    }

    pub fn lessThan(_: void, left: Item, right: Item) bool {
        return std.mem.lessThan(u8, left.label, right.label);
    }
};

pub fn deinit(gpa: std.mem.Allocator, items: *std.ArrayList(Item)) void {
    for (items.items) |item| item.deinit(gpa);
    items.deinit(gpa);
}

fn insertion(gpa: std.mem.Allocator, item: *Item, parameters: bool) !void {
    item.insertText = try std.fmt.allocPrint(gpa, "{s}({s})", .{ item.label, if (parameters) "$0" else "" });
    item.insertTextFormat = if (parameters) 2 else 1;
}

/// Substitute only the receiver's known generic parameters. A map's U stays
/// U: completion does not invent the result of a block not yet written.
fn writeType(out: *std.Io.Writer, text: []const u8, receiver: ?Type) !void {
    var index: usize = 0;
    while (index < text.len) {
        const start = index;
        if (!std.ascii.isAlphabetic(text[index])) {
            try out.writeByte(text[index]);
            index += 1;
            continue;
        }
        while (index < text.len and std.ascii.isAlphanumeric(text[index])) : (index += 1) {}
        const word = text[start..index];
        const actual: ?Type = if (receiver) |base| blk: {
            if (base.optional and std.mem.eql(u8, word, "T")) break :blk base.payload();
            if (std.mem.eql(u8, word, "T") or (base.kind == .dictionary and std.mem.eql(u8, word, "V"))) {
                if (base.element) |element| break :blk element.*;
            }
            if (std.mem.eql(u8, word, "K")) {
                if (base.key) |key| break :blk key.*;
            }
            break :blk null;
        } else null;
        if (actual) |found| try out.print("{f}", .{found}) else try out.writeAll(word);
    }
}

pub fn native(gpa: std.mem.Allocator, member: Builtins.Member, receiver: ?Type) !Item {
    const signature_receiver = if (receiver) |base| if (base.kind == .list and std.mem.eql(u8, member.name, "to_dictionary") and base.element.?.kind == .tuple and base.element.?.elements.len == 2)
        Type{ .kind = .dictionary, .key = &base.element.?.elements[0], .element = &base.element.?.elements[1] }
    else
        base else null;
    var item: Item = .{ .label = member.name, .kind = switch (member.kind) {
        .method, .type_method => 2,
        .property, .type_property => 10,
        .function => 3,
        .statement => 14,
    } };
    errdefer item.deinit(gpa);
    var detail: std.Io.Writer.Allocating = .init(gpa);
    defer detail.deinit();
    var parameters = false;
    for (member.signatures, 0..) |signature, index| {
        if (index != 0) try detail.writer.writeByte('\n');
        try detail.writer.writeAll(member.name);
        if (member.kind != .property and member.kind != .type_property) {
            try detail.writer.writeByte('(');
            for (signature.parameters, 0..) |parameter, parameter_index| {
                if (parameter_index != 0) try detail.writer.writeAll(", ");
                try detail.writer.print("{s}: ", .{parameter.name});
                try writeType(&detail.writer, parameter.type, signature_receiver);
                if (parameter.variadic) try detail.writer.writeAll("...");
                if (parameter.default) |value| try detail.writer.print(" = {s}", .{value}) else if (parameter.optional) try detail.writer.writeAll(" (optional)");
            }
            try detail.writer.writeByte(')');
            parameters = parameters or signature.parameters.len != 0;
        }
        if (signature.block) |block| {
            try detail.writer.writeAll(" { ");
            try writeType(&detail.writer, block, signature_receiver);
            try detail.writer.writeAll(" }");
        }
        try detail.writer.writeAll(": ");
        try writeType(&detail.writer, signature.result, signature_receiver);
    }
    item.detail = try detail.toOwnedSlice();
    item.documentation = try gpa.dupe(u8, member.signatures[0].summary);
    if (member.kind == .method or member.kind == .type_method or member.kind == .function) try insertion(gpa, &item, parameters);
    return item;
}

pub fn function(gpa: std.mem.Allocator, source: *const emerald.Source, declaration: emerald.Ast.FunctionDeclaration, label: []const u8, kind: u8, inferred_result: ?Type) !Item {
    var item: Item = .{ .label = label, .kind = kind };
    errdefer item.deinit(gpa);
    var detail: std.Io.Writer.Allocating = .init(gpa);
    defer detail.deinit();
    try detail.writer.print("{s}(", .{label});
    for (declaration.parameters, 0..) |parameter, index| {
        if (index != 0) try detail.writer.writeAll(", ");
        try detail.writer.print("{s}: {s}", .{ parameter.name, annotationText(source, parameter.annotation) });
        if (parameter.default) |value| try detail.writer.print(" = {s}", .{sourceText(source, value.span)});
    }
    try detail.writer.writeAll("): ");
    if (declaration.return_annotation) |annotation| {
        try detail.writer.writeAll(annotationText(source, annotation));
    } else if (inferred_result) |result| {
        try detail.writer.print("{f}", .{result});
    } else {
        // Failed resolution has no checked signatures. Do not guess Nothing
        // for an unannotated function that may return a value.
        try detail.writer.writeAll("(inferred)");
    }
    item.detail = try detail.toOwnedSlice();
    item.documentation = try documentation(gpa, source, declaration.name_span);
    try insertion(gpa, &item, declaration.parameters.len != 0);
    try humanizePrelude(gpa, &item, source);
    return item;
}

pub fn field(gpa: std.mem.Allocator, source: *const emerald.Source, label: []const u8, span: emerald.Source.Span, annotation: ?emerald.Ast.TypeExpression, initializer: ?*const emerald.Ast.Expression, inferred: ?Type, kind: u8) !Item {
    var item: Item = .{ .label = label, .kind = kind };
    errdefer item.deinit(gpa);
    item.detail = if (inferred) |actual|
        try std.fmt.allocPrint(gpa, "{s}: {f}", .{ label, actual })
    else if (annotation) |written|
        try std.fmt.allocPrint(gpa, "{s}: {s}", .{ label, annotationText(source, written) })
    else if (initializer) |value|
        // Failed resolution has no checked types. Show the real declaration,
        // rather than guessing the initializer's type in a second type system.
        try std.fmt.allocPrint(gpa, "{s} = {s}", .{ label, sourceText(source, value.span) })
    else
        try gpa.dupe(u8, label);
    item.documentation = try documentation(gpa, source, span);
    try humanizePrelude(gpa, &item, source);
    return item;
}

fn annotationText(source: *const emerald.Source, annotation: emerald.Ast.TypeExpression) []const u8 {
    // TypeExpression.span names the present type; question_span owns the
    // trailing optional marker. Leaving it out misdescribes parse_maybe.
    return source.text[annotation.span.start..if (annotation.question_span) |question| question.end else annotation.span.end];
}

fn humanizePrelude(gpa: std.mem.Allocator, item: *Item, source: *const emerald.Source) !void {
    if (!std.mem.eql(u8, source.path, "prelude.em")) return;
    const old = item.detail orelse return;
    const readable = try std.mem.replaceOwned(u8, gpa, old, emerald.Resolver.prelude_namespace ++ ".", "");
    gpa.free(old);
    item.detail = readable;
}

fn sourceText(source: *const emerald.Source, span: emerald.Source.Span) []const u8 {
    return source.text[span.start..span.end];
}

/// Read consecutive documentation lines above the declaration, crossing only
/// its annotations. Blank lines and ordinary comments break attachment (3.2).
pub fn documentation(gpa: std.mem.Allocator, source: *const emerald.Source, span: emerald.Source.Span) !?[]const u8 {
    var line = source.location(span.start).line;
    while (line > 1 and std.mem.startsWith(u8, std.mem.trim(u8, source.lineText(line - 1), " \t\r"), "@")) line -= 1;
    const end = line;
    while (line > 1 and std.mem.startsWith(u8, std.mem.trim(u8, source.lineText(line - 1), " \t\r"), "##")) line -= 1;
    if (line == end) return null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (line..end) |number| {
        const written = std.mem.trim(u8, source.lineText(@intCast(number)), " \t\r");
        if (text.items.len != 0) try text.append(gpa, '\n');
        try text.appendSlice(gpa, std.mem.trimStart(u8, written[2..], " "));
    }
    return try text.toOwnedSlice(gpa);
}
