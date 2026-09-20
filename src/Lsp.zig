//! `emerald lsp` (section 18.5): a Language Server Protocol server over
//! stdio. This first slice covers what already reuses the compiler almost
//! unchanged — live diagnostics, document symbols, and format on save — and
//! deliberately does not advertise hover, go to definition, find references,
//! rename, or completion, which each need real new infrastructure this slice
//! does not build (an offset→AST-node lookup that exists nowhere yet, a
//! general per-expression type map where today only a few narrow expression
//! kinds are recorded, and — for completion specifically — a materially
//! different parser recovery strategy, since today a broken construct like
//! `foo.` discards its whole enclosing statement rather than leaving a
//! partial node to offer completions against).
//!
//! Wire format: JSON-RPC 2.0 framed as `Content-Length: N\r\n\r\n` followed
//! by exactly N bytes of JSON (LSP's own framing, independent of JSON-RPC
//! itself). Messages are read and written as the dynamic `std.json.Value`
//! tree on the way in — inspecting `.method`/`.id`/`.params` by hand fits
//! JSON-RPC's per-method varying shape better than one fixed struct for every
//! possible message — and as plain Zig struct/slice literals on the way out,
//! relying on `std.json.Stringify.write`'s reflection to serialize them
//! directly; a `std.json.Value` (such as an echoed-back request `id`, which
//! may be a number or a string) can be embedded in either direction, since
//! `Value` implements its own `jsonStringify`.
//!
//! One document store, one arena per request that needs to build a tree
//! (document symbols, formatting) — this mirrors `src/Repl.zig`'s own
//! pattern of building a throwaway in-memory `Source` from whatever text is
//! current, rather than ever touching disk.

const std = @import("std");
const emerald = @import("emerald");
const Source = emerald.Source;
const Lexer = emerald.Lexer;
const Parser = emerald.Parser;
const Ast = emerald.Ast;
const Formatter = emerald.Formatter;
const unicode = emerald.unicode;

// Wire shapes. Plain Zig types `std.json.Stringify.write` serializes by
// reflection — no JSON-specific annotation needed on any of them.

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const LspDiagnostic = struct { range: Range, severity: u32, message: []const u8 };
const DocumentSymbol = struct {
    name: []const u8,
    kind: u32,
    range: Range,
    selectionRange: Range,
    children: []const DocumentSymbol = &.{},
};
const TextEdit = struct { range: Range, newText: []const u8 };

/// LSP `SymbolKind` values this slice actually uses (the full enum has 26;
/// only the ones Emerald's declarations map onto are named here).
const SymbolKind = struct {
    const class = 5;
    const method = 6;
    const property = 7;
    const field = 8;
    const constructor = 9;
    const @"enum" = 10;
    const interface = 11;
    const function = 12;
    const variable = 13;
    const constant = 14;
    const enum_member = 22;
    const @"struct" = 23;
};

/// A byte offset `span` from `source` becomes an LSP `Range`: zero-based
/// lines, and a `character` counted in UTF-16 code units — `Source.location`
/// gives a one-based line and a Unicode-*scalar* column, and neither matches
/// what LSP positions are defined in terms of, so this walks the line's own
/// text and re-counts.
fn lspRange(source: *const Source, span: Source.Span) Range {
    return .{ .start = lspPosition(source, span.start), .end = lspPosition(source, span.end) };
}

fn lspPosition(source: *const Source, offset: u32) Position {
    const location = source.location(offset);
    const line_start = source.line_starts[location.line - 1];
    const line_text = source.lineText(location.line);
    const byte_in_line = @min(offset - line_start, @as(u32, @intCast(line_text.len)));

    var character: u32 = 0;
    var i: u32 = 0;
    while (i < byte_in_line) {
        const decoded = unicode.decode(line_text, i);
        character += std.unicode.utf16CodepointSequenceLength(decoded[0]) catch 1;
        i += decoded[1];
    }
    return .{ .line = location.line - 1, .character = character };
}

const Document = struct {
    text: std.ArrayList(u8) = .empty,

    fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.* = undefined;
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    documents: std.StringHashMapUnmanaged(Document) = .empty,

    fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.gpa);
        }
        self.documents.deinit(self.gpa);
        self.* = undefined;
    }

    /// Replaces the stored text for `uri` (full-document sync only, per this
    /// slice's scope), owning its own copy of the URI the first time it is
    /// seen.
    fn store(self: *Server, uri: []const u8, text: []const u8) !void {
        const gop = try self.documents.getOrPut(self.gpa, uri);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, uri);
            gop.value_ptr.* = .{};
        } else {
            gop.value_ptr.text.clearRetainingCapacity();
        }
        try gop.value_ptr.text.appendSlice(self.gpa, text);
    }

    fn forget(self: *Server, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            var doc = kv.value;
            doc.deinit(self.gpa);
        }
    }
};

/// Runs until `exit` or a clean end of the input stream (the client closed
/// its side of stdio).
pub fn run(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var server: Server = .{ .gpa = gpa };
    defer server.deinit();

    while (true) {
        var parsed = readMessage(gpa, in) catch |err| switch (err) {
            // The body was read in full regardless, so the stream is still
            // correctly positioned at the next message: safe to skip.
            error.InvalidJson => continue,
            // Anything else (a framing problem, or the transport itself
            // failing) leaves the reader's position no longer trustworthy.
            else => |e| return e,
        } orelse break;
        defer parsed.deinit();

        const should_exit = handle(&server, gpa, parsed.value, out) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => |e| return e,
            // A malformed or unexpected message is not fatal to the session;
            // whatever request it was simply goes unanswered.
            else => false,
        };
        if (should_exit) break;
    }
}

// Transport.

/// Reads one full JSON-RPC message (headers, then exactly `Content-Length`
/// bytes of JSON body), or `null` at a clean end of input with nothing
/// left — the same distinction `Repl.zig`'s `readLine` makes for stdin.
fn readMessage(gpa: std.mem.Allocator, in: *std.Io.Reader) !?std.json.Parsed(std.json.Value) {
    var content_length: ?usize = null;
    while (true) {
        const line = (try readLine(gpa, in)) orelse return null;
        defer gpa.free(line);
        if (line.len == 0) break; // the blank line ending the headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
        // Any other header (`Content-Type`, ...) is not needed and skipped.
    }
    const length = content_length orelse return error.MissingContentLength;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    in.streamExact(&body.writer, length) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    // The body is exactly `length` bytes regardless of whether it parses, so
    // malformed JSON here does not desync the stream — `run` treats this one
    // specific error as "skip this message," unlike a framing problem above,
    // where the reader's position can no longer be trusted.
    return std.json.parseFromSlice(std.json.Value, gpa, body.written(), .{}) catch return error.InvalidJson;
}

/// One line without its terminator, `null` only at a clean end of input —
/// the exact idiom `src/Repl.zig`'s `readLine` and `Interpreter.evaluateInput`
/// already use for stdin.
fn readLine(gpa: std.mem.Allocator, in: *std.Io.Reader) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    const length = in.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    const at_end = in.bufferedLen() == 0;
    if (!at_end) in.toss(1); // the newline
    if (at_end and length == 0) return null;
    return try gpa.dupe(u8, std.mem.trimEnd(u8, line.written(), "\r"));
}

fn writeMessage(gpa: std.mem.Allocator, out: *std.Io.Writer, value: anytype) !void {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var stringify: std.json.Stringify = .{ .writer = &body.writer, .options = .{} };
    try stringify.write(value);
    try out.print("Content-Length: {d}\r\n\r\n", .{body.written().len});
    try out.writeAll(body.written());
    try out.flush();
}

fn respond(gpa: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, result: anytype) !void {
    try writeMessage(gpa, out, .{ .jsonrpc = "2.0", .id = id, .result = result });
}

fn respondMethodNotFound(gpa: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value) !void {
    try writeMessage(gpa, out, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = @as(i32, -32601), .message = "method not found" },
    });
}

fn notify(gpa: std.mem.Allocator, out: *std.Io.Writer, method: []const u8, params: anytype) !void {
    try writeMessage(gpa, out, .{ .jsonrpc = "2.0", .method = method, .params = params });
}

// Dispatch.

/// Returns whether the server should stop (`exit`).
fn handle(server: *Server, gpa: std.mem.Allocator, message: std.json.Value, out: *std.Io.Writer) !bool {
    if (message != .object) return false;
    const method_value = message.object.get("method") orelse return false;
    if (method_value != .string) return false;
    const method = method_value.string;
    const id = message.object.get("id");
    const params = message.object.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        if (id) |request_id| try respond(gpa, out, request_id, .{
            .capabilities = .{
                .textDocumentSync = .{ .openClose = true, .change = 1 },
                .documentSymbolProvider = true,
                .documentFormattingProvider = true,
            },
        });
        return false;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        if (id) |request_id| try respond(gpa, out, request_id, null);
        return false;
    }
    if (std.mem.eql(u8, method, "exit")) return true;
    if (std.mem.eql(u8, method, "initialized")) return false;

    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const text = try stringField(text_document, "text");
        try server.store(uri, text);
        try publishDiagnostics(server, gpa, uri, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const changes = try arrayField(params, "contentChanges");
        // Full-document sync: the one change this slice expects carries the
        // whole new text, not a range to apply.
        if (changes.items.len == 0) return false;
        const text = try stringField(changes.items[changes.items.len - 1], "text");
        try server.store(uri, text);
        try publishDiagnostics(server, gpa, uri, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        server.forget(uri);
        try notify(gpa, out, "textDocument/publishDiagnostics", .{
            .uri = uri,
            .diagnostics = @as([]const LspDiagnostic, &.{}),
        });
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        if (id) |request_id| try onDocumentSymbol(server, gpa, uri, request_id, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        if (id) |request_id| try onFormatting(server, gpa, uri, request_id, out);
        return false;
    }

    // Anything else, including every deferred feature (hover, definition,
    // references, rename, completion) and `$/cancelRequest`: a well-formed
    // "not found" for a request, silently ignored for a notification —
    // never a crash or a hang either way.
    if (id) |request_id| try respondMethodNotFound(gpa, out, request_id);
    return false;
}

fn objectField(maybe_params: ?std.json.Value, name: []const u8) !std.json.Value {
    const params = maybe_params orelse return error.InvalidParams;
    if (params != .object) return error.InvalidParams;
    const field = params.object.get(name) orelse return error.InvalidParams;
    if (field != .object) return error.InvalidParams;
    return field;
}

fn stringField(container: std.json.Value, name: []const u8) ![]const u8 {
    if (container != .object) return error.InvalidParams;
    const field = container.object.get(name) orelse return error.InvalidParams;
    if (field != .string) return error.InvalidParams;
    return field.string;
}

fn arrayField(maybe_params: ?std.json.Value, name: []const u8) !std.json.Array {
    const params = maybe_params orelse return error.InvalidParams;
    if (params != .object) return error.InvalidParams;
    const field = params.object.get(name) orelse return error.InvalidParams;
    if (field != .array) return error.InvalidParams;
    return field.array;
}

// Live diagnostics.

fn publishDiagnostics(server: *Server, gpa: std.mem.Allocator, uri: []const u8, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse return;

    var source = try Source.init(gpa, uri, document.text.items);
    defer source.deinit(gpa);

    var report = try emerald.check(gpa, &source);
    defer report.deinit();

    var diagnostics: std.ArrayList(LspDiagnostic) = .empty;
    defer diagnostics.deinit(gpa);
    for (report.diagnostics) |diagnostic| {
        try diagnostics.append(gpa, .{
            .range = lspRange(&source, diagnostic.span),
            // LSP's `DiagnosticSeverity`: 1 is Error, 2 is Warning.
            .severity = if (diagnostic.severity == .warning) 2 else 1,
            .message = diagnostic.message,
        });
    }
    try notify(gpa, out, "textDocument/publishDiagnostics", .{
        .uri = uri,
        .diagnostics = diagnostics.items,
    });
}

// Document symbols.

fn onDocumentSymbol(server: *Server, gpa: std.mem.Allocator, uri: []const u8, id: std.json.Value, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, @as([]const DocumentSymbol, &.{}));
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try Source.init(arena, uri, document.text.items);
    const tokenized = try Lexer.tokenize(arena, &source);
    const parsed = try Parser.parse(arena, &source, tokenized.tokens);

    const symbols = try documentSymbols(arena, &source, parsed.program);
    try respond(gpa, out, id, symbols);
}

fn documentSymbols(arena: std.mem.Allocator, source: *const Source, program: Ast.Program) ![]const DocumentSymbol {
    var symbols: std.ArrayList(DocumentSymbol) = .empty;
    for (program.statements) |statement| {
        switch (statement.data) {
            .function_declaration => |f| try symbols.append(arena, .{
                .name = f.name,
                .kind = SymbolKind.function,
                .range = lspRange(source, statement.span),
                .selectionRange = lspRange(source, f.name_span),
            }),
            .struct_declaration => |s| try symbols.append(arena, try structSymbol(arena, source, statement.span, s)),
            .declaration => |d| try symbols.append(arena, .{
                .name = d.name,
                .kind = if (d.mutable) SymbolKind.variable else SymbolKind.constant,
                .range = lspRange(source, statement.span),
                .selectionRange = lspRange(source, d.name_span),
            }),
            else => {},
        }
    }
    return symbols.items;
}

fn structSymbol(arena: std.mem.Allocator, source: *const Source, span: Source.Span, s: Ast.StructDeclaration) !DocumentSymbol {
    const kind: u32 = if (s.trait) SymbolKind.interface else if (s.class) SymbolKind.class else if (s.enumeration) SymbolKind.@"enum" else SymbolKind.@"struct";

    var children: std.ArrayList(DocumentSymbol) = .empty;
    for (s.fields) |field| try children.append(arena, .{
        .name = field.name,
        .kind = SymbolKind.field,
        .range = lspRange(source, field.name_span),
        .selectionRange = lspRange(source, field.name_span),
    });
    if (s.constructor) |constructor| try children.append(arena, .{
        .name = "constructor",
        .kind = SymbolKind.constructor,
        .range = lspRange(source, constructor.keyword_span),
        .selectionRange = lspRange(source, constructor.keyword_span),
    });
    for (s.methods) |method| try children.append(arena, .{
        .name = method.name,
        .kind = SymbolKind.method,
        .range = lspRange(source, method.name_span),
        .selectionRange = lspRange(source, method.name_span),
    });
    for (s.properties) |property| try children.append(arena, .{
        .name = property.name,
        .kind = SymbolKind.property,
        .range = lspRange(source, property.name_span),
        .selectionRange = lspRange(source, property.name_span),
    });
    for (s.type_functions) |type_function| try children.append(arena, .{
        .name = type_function.declaration.name,
        .kind = SymbolKind.function,
        .range = lspRange(source, type_function.member_span),
        .selectionRange = lspRange(source, type_function.member_span),
    });
    for (s.type_fields) |type_field| try children.append(arena, .{
        .name = type_field.name,
        .kind = if (type_field.enum_value != null) SymbolKind.enum_member else SymbolKind.field,
        .range = lspRange(source, type_field.name_span),
        .selectionRange = lspRange(source, type_field.name_span),
    });

    return .{
        .name = s.name,
        .kind = kind,
        .range = lspRange(source, span),
        .selectionRange = lspRange(source, s.name_span),
        .children = children.items,
    };
}

// Format on save.

fn onFormatting(server: *Server, gpa: std.mem.Allocator, uri: []const u8, id: std.json.Value, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, @as([]const TextEdit, &.{}));
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try Source.init(arena, uri, document.text.items);
    const tokenized = try Lexer.tokenize(arena, &source);
    const parsed = if (tokenized.diagnostics.len == 0) try Parser.parse(arena, &source, tokenized.tokens) else null;

    // 18.3: refuses to rewrite a file it cannot parse safely — no edit at all.
    if (tokenized.diagnostics.len != 0 or parsed.?.diagnostics.len != 0) {
        try respond(gpa, out, id, @as([]const TextEdit, &.{}));
        return;
    }

    const formatted = try Formatter.print(arena, &source, tokenized.tokens, parsed.?.program);
    const whole_document = Source.Span{ .start = 0, .end = @intCast(document.text.items.len) };
    const edit = TextEdit{ .range = lspRange(&source, whole_document), .newText = formatted };
    try respond(gpa, out, id, &[_]TextEdit{edit});
}

const testing = std.testing;

test "a framed message round-trips through reading and writing" {
    const gpa = testing.allocator;
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try writeMessage(gpa, &body.writer, .{ .jsonrpc = "2.0", .id = @as(i64, 7), .method = "ping" });

    var reader: std.Io.Reader = .fixed(body.written());
    var parsed = (try readMessage(gpa, &reader)).?;
    defer parsed.deinit();

    try testing.expectEqualStrings("ping", parsed.value.object.get("method").?.string);
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
}

test "reading stops cleanly at the end of input" {
    const gpa = testing.allocator;
    var reader: std.Io.Reader = .fixed("");
    try testing.expectEqual(@as(?std.json.Parsed(std.json.Value), null), try readMessage(gpa, &reader));
}

test "UTF-16 position conversion: ASCII, a BMP scalar, and an astral scalar" {
    const gpa = testing.allocator;

    // "café" — é (U+00E9) is one UTF-16 unit, same as any ASCII character.
    {
        var source = try Source.init(gpa, "t.em", "café\n");
        defer source.deinit(gpa);
        const position = lspPosition(&source, 5); // byte offset right after "café"
        try testing.expectEqual(Position{ .line = 0, .character = 4 }, position);
    }

    // An emoji (U+1F389, astral) needs a surrogate pair: two UTF-16 units.
    {
        var source = try Source.init(gpa, "t.em", "a🎉b\n");
        defer source.deinit(gpa);
        // "a" (1 byte) + the emoji (4 bytes) = byte offset 5, right before "b".
        const position = lspPosition(&source, 5);
        try testing.expectEqual(Position{ .line = 0, .character = 3 }, position);
    }
}

fn parseFixed(gpa: std.mem.Allocator, text: []const u8) !struct { source: Source, parsed: Parser.Parsed } {
    var source = try Source.init(gpa, "t.em", text);
    var tokenized = try Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    const parsed = try Parser.parse(gpa, &source, tokenized.tokens);
    return .{ .source = source, .parsed = parsed };
}

test "document symbols cover a struct's members, an enum's values, and a trait's requirement" {
    const gpa = testing.allocator;
    var fixed = try parseFixed(gpa,
        \\struct Point {
        \\    var x: Float
        \\
        \\    func total(): Float {
        \\        return self.x
        \\    }
        \\}
        \\
        \\enum Direction {
        \\    north
        \\}
        \\
        \\trait Named {
        \\    const name: String
        \\}
        \\
    );
    defer fixed.source.deinit(gpa);
    defer fixed.parsed.deinit();
    try testing.expectEqual(@as(usize, 0), fixed.parsed.diagnostics.len);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const symbols = try documentSymbols(arena_state.allocator(), &fixed.source, fixed.parsed.program);

    try testing.expectEqual(@as(usize, 3), symbols.len);

    try testing.expectEqualStrings("Point", symbols[0].name);
    try testing.expectEqual(@as(u32, SymbolKind.@"struct"), symbols[0].kind);
    try testing.expectEqual(@as(usize, 2), symbols[0].children.len);
    try testing.expectEqualStrings("x", symbols[0].children[0].name);
    try testing.expectEqual(@as(u32, SymbolKind.field), symbols[0].children[0].kind);
    try testing.expectEqualStrings("total", symbols[0].children[1].name);
    try testing.expectEqual(@as(u32, SymbolKind.method), symbols[0].children[1].kind);

    try testing.expectEqualStrings("Direction", symbols[1].name);
    try testing.expectEqual(@as(u32, SymbolKind.@"enum"), symbols[1].kind);
    try testing.expectEqualStrings("north", symbols[1].children[0].name);
    try testing.expectEqual(@as(u32, SymbolKind.enum_member), symbols[1].children[0].kind);

    try testing.expectEqualStrings("Named", symbols[2].name);
    try testing.expectEqual(@as(u32, SymbolKind.interface), symbols[2].kind);
    try testing.expectEqualStrings("name", symbols[2].children[0].name);
    try testing.expectEqual(@as(u32, SymbolKind.property), symbols[2].children[0].kind);
}
