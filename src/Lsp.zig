//! `emerald lsp` (section 18.5): a Language Server Protocol server over
//! stdio. The first slice covered what already reused the compiler almost
//! unchanged — live diagnostics, document symbols, and format on save — all
//! naturally file-scoped, needing no more than the one open document.
//!
//! Hover is the second slice's first piece. It needed two things the first
//! slice's file-scoped features never did: an expression's inferred type
//! (`Checker.zig`'s `expression_types`, every expression's type by
//! expression, not only the few kinds `literal_types` tracked for the
//! interpreter's sake) and a document's whole project (14.1), since a file
//! checked alone sees none of its own project's other declarations —
//! `loadDocument` below reads one from disk, substituting the editor's own
//! buffer for the open file.
//!
//! Go to definition is the second piece, answered by three facts
//! `Resolver.zig`'s existing hoisting pass now also records: `declarations`
//! (every module-level symbol's own name span), `expression_targets` (every
//! name read's resolved declaration), and `assignment_targets` (the same, for
//! assignment destinations). A member access, a call's own callee (resolved
//! separately from `expressionAt`'s hover lookup — `Checker.typeOfCall` never
//! gives the callee itself an entry in `expression_types`), a written type
//! annotation, and a declaration name each get their own small walk of the
//! statement tree below, since none of them is a name read the resolver
//! already tracked.
//!
//! Find references is the third piece, the same three facts read the other
//! way: given a declaration's site, one ordinary recursive descent through
//! every file's whole statement and expression tree collects every read,
//! write, and type use whose own resolved site matches it. Rename after
//! that, built directly on find references; completion last, since it alone
//! needs a different parser recovery strategy — today a broken construct
//! like `foo.` discards its whole enclosing statement rather than leaving a
//! partial node to offer completions against.
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
//! current. `loadDocument` is the one exception: hover and everything after
//! it need a document's project, which only disk knows.

const std = @import("std");
const emerald = @import("emerald");
const Source = emerald.Source;
const Lexer = emerald.Lexer;
const Parser = emerald.Parser;
const Ast = emerald.Ast;
const Formatter = emerald.Formatter;
const unicode = emerald.unicode;
const Project = emerald.Project;
const Type = emerald.Type;
const Resolver = emerald.Resolver;

// Wire shapes. Plain Zig types `std.json.Stringify.write` serializes by
// reflection — no JSON-specific annotation needed on any of them.

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const Location = struct { uri: []const u8, range: Range };
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

/// The inverse of `lspPosition`: an LSP position (zero-based line, UTF-16
/// code units into it) to a byte offset. A line or character past the end of
/// the text clamps to the nearest valid offset rather than indexing out of
/// range — a client's position can be stale by one keystroke the moment a
/// fast edit follows a request.
fn offsetFromPosition(source: *const Source, position: Position) u32 {
    const last_line = @as(u32, @intCast(source.line_starts.len));
    const line = @min(position.line + 1, last_line);
    const line_start = source.line_starts[line - 1];
    const line_text = source.lineText(line);

    var character: u32 = 0;
    var i: u32 = 0;
    while (i < line_text.len and character < position.character) {
        const decoded = unicode.decode(line_text, i);
        character += std.unicode.utf16CodepointSequenceLength(decoded[0]) catch 1;
        i += decoded[1];
    }
    return line_start + i;
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
    /// For reading a document's project (14.1) from disk. Every other server
    /// operation stays in memory (see this file's header); this is the one
    /// exception, needed for any feature that has to see beyond one file.
    io: std.Io,
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

// Loading a document's project (14.1).
//
// Every feature above this needs only the one open file (diagnostics,
// document symbols, formatting are all naturally file-scoped), so the header
// comment's "rather than ever touching disk" held for the first slice. Hover
// and everything after it type-check the file, and a file inside a real
// project checked alone sees none of its own project's other declarations —
// exactly the false "not defined" a lone `.em` file never has. `loadDocument`
// is the one place this file reads from disk, reusing `Project.load`, the
// same loader the CLI uses.

/// A document's project (14.1) and which of its files the document itself is.
const Loaded = struct {
    project: Project,
    /// Index into `project.files` (and `project.sources()`) of the open
    /// document, so a diagnostic or a hover result can be matched back to it.
    index: u32,

    fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        self.project.deinit(gpa);
        self.* = undefined;
    }
};

/// Loads the project `uri` belongs to, substituting `text` — the editor's own
/// buffer, which may hold unsaved edits — for that one file, and reading
/// every other file of a multi-file project from disk, the best available
/// text for a file the editor has not opened. Falls back to a project of the
/// one open document by itself, exactly how a lone `.em` file already works
/// everywhere else, when `uri` names no real path, the project cannot be read
/// (most commonly a new, unsaved file), or — a path mismatch too unusual to
/// silently paper over — its own path is not among the files found there.
fn loadDocument(server: *Server, gpa: std.mem.Allocator, uri: []const u8, text: []const u8) !Loaded {
    if (try loadProjectFor(server, gpa, uri, text)) |loaded| return loaded;
    const source = try Source.init(gpa, uri, text);
    const files = try gpa.alloc(Project.File, 1);
    files[0] = .{ .source = source, .namespace = "", .entry = true };
    return .{ .project = .{ .files = files, .entry = 0, .bad_directories = &.{} }, .index = 0 };
}

fn loadProjectFor(server: *Server, gpa: std.mem.Allocator, uri: []const u8, text: []const u8) !?Loaded {
    const path = (try uriToPath(gpa, uri)) orelse return null;
    defer gpa.free(path);
    var project = Project.load(gpa, server.io, path) catch return null;
    errdefer project.deinit(gpa);
    for (project.files, 0..) |*file, index| {
        if (!std.mem.eql(u8, file.source.path, path)) continue;
        const replaced = try Source.init(gpa, path, text);
        file.source.deinit(gpa);
        file.source = replaced;
        return .{ .project = project, .index = @intCast(index) };
    }
    project.deinit(gpa);
    return null;
}

/// A `file://` URI to a plain, percent-decoded filesystem path. Null for any
/// other scheme (an editor's unsaved, never-written buffer commonly gets
/// `untitled:`), which has no project to load.
fn uriToPath(gpa: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // `file:///C:/Users/...`: the leading slash before a Windows drive letter
    // is the URI's, not the path's.
    if (rest.len >= 3 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') {
        rest = rest[1..];
    }
    return try percentDecode(gpa, rest);
}

fn percentDecode(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The inverse of `uriToPath`: converts a filesystem path to a `file://` URI,
/// percent-encoding characters outside the unreserved set, and ensuring
/// Windows drive letters have a leading slash (`file:///C:/...`). `path`
/// itself is always absolute here — it comes from a `Project.File.source.path`
/// built from `uriToPath`'s own decoded, absolute path (`loadProjectFor`) — so
/// an unexpectedly relative one is a bug upstream to surface, not a shape to
/// paper over by guessing where root is.
fn pathToUri(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "file://")) return try gpa.dupe(u8, path);

    const has_drive_letter = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    std.debug.assert(has_drive_letter or (path.len > 0 and (path[0] == '/' or path[0] == '\\')));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "file://");
    if (has_drive_letter) try out.append(gpa, '/');

    for (path) |b| {
        const c = if (b == '\\') '/' else b;
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~', '/', ':' => try out.append(gpa, c),
            else => {
                const hex = "0123456789ABCDEF";
                try out.append(gpa, '%');
                try out.append(gpa, hex[(c >> 4) & 0xF]);
                try out.append(gpa, hex[c & 0xF]);
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Runs until `exit` or a clean end of the input stream (the client closed
/// its side of stdio).
pub fn run(gpa: std.mem.Allocator, io: std.Io, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var server: Server = .{ .gpa = gpa, .io = io };
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
                .hoverProvider = true,
                .definitionProvider = true,
                .referencesProvider = true,
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
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        if (id) |request_id| try onHover(server, gpa, uri, position, request_id, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        if (id) |request_id| try onDefinition(server, gpa, uri, position, request_id, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/references")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        const include_declaration = includeDeclarationField(params);
        if (id) |request_id| try onReferences(server, gpa, uri, position, include_declaration, request_id, out);
        return false;
    }

    // Anything else, including every feature still deferred (rename,
    // completion) and `$/cancelRequest`: a well-formed "not found" for a
    // request, silently ignored for a notification — never a crash or a
    // hang either way.
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

fn intField(container: std.json.Value, name: []const u8) !i64 {
    if (container != .object) return error.InvalidParams;
    const field = container.object.get(name) orelse return error.InvalidParams;
    if (field != .integer) return error.InvalidParams;
    return field.integer;
}

fn positionField(maybe_params: ?std.json.Value) !Position {
    const position = try objectField(maybe_params, "position");
    return .{
        .line = std.math.cast(u32, try intField(position, "line")) orelse return error.InvalidParams,
        .character = std.math.cast(u32, try intField(position, "character")) orelse return error.InvalidParams,
    };
}

fn arrayField(maybe_params: ?std.json.Value, name: []const u8) !std.json.Array {
    const params = maybe_params orelse return error.InvalidParams;
    if (params != .object) return error.InvalidParams;
    const field = params.object.get(name) orelse return error.InvalidParams;
    if (field != .array) return error.InvalidParams;
    return field.array;
}

/// `textDocument/references`'s `context.includeDeclaration`, defaulted
/// rather than required — unlike a position or a URI, a client omitting or
/// misshaping this one preference is not malformed enough to fail the whole
/// request over.
fn includeDeclarationField(maybe_params: ?std.json.Value) bool {
    const params = maybe_params orelse return false;
    if (params != .object) return false;
    const context = params.object.get("context") orelse return false;
    if (context != .object) return false;
    const field = context.object.get("includeDeclaration") orelse return false;
    return field == .bool and field.bool;
}

// Live diagnostics.

fn publishDiagnostics(server: *Server, gpa: std.mem.Allocator, uri: []const u8, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse return;

    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);

    var report = try emerald.checkProject(gpa, &loaded.project);
    defer report.deinit();

    const source = &loaded.project.files[loaded.index].source;
    var diagnostics: std.ArrayList(LspDiagnostic) = .empty;
    defer diagnostics.deinit(gpa);
    for (report.diagnostics) |diagnostic| {
        // A project's other files are checked too, so their share of the
        // whole project's diagnostics still needs its own report — not
        // published here, since this document's editor is the only one this
        // server currently has open enough to ask for again.
        if (diagnostic.file != loaded.index) continue;
        try diagnostics.append(gpa, .{
            .range = lspRange(source, diagnostic.span),
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

// Hover.

const Hover = struct {
    contents: MarkupContent,
    range: Range,
};

const MarkupContent = struct {
    kind: []const u8 = "plaintext",
    value: []const u8,
};

fn onHover(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, id: std.json.Value, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, null);
        return;
    };

    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);

    var analysis = (try emerald.analyzeProject(gpa, &loaded.project)) orelse {
        try respond(gpa, out, id, null);
        return;
    };
    defer analysis.deinit(gpa);

    const source = &loaded.project.files[loaded.index].source;
    const offset = offsetFromPosition(source, position);
    const found = expressionAt(&analysis, loaded.index, offset) orelse {
        try respond(gpa, out, id, null);
        return;
    };

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.print("{f}", .{found.type});

    try respond(gpa, out, id, Hover{
        .contents = .{ .value = text.written() },
        .range = lspRange(source, found.span),
    });
}

const Found = struct { span: Source.Span, type: Type, expression: *const Ast.Expression };

/// The smallest expression of `analysis`'s checked types whose own file is
/// `file` and whose span contains `offset` — the innermost thing the cursor
/// is on, since a member access's base name is its own smaller expression
/// nested inside the whole access. Prefers no expression over an ambiguous
/// tie, which two expressions of the same span cannot produce today, since
/// every kind of expression node owns a distinct span from what it wraps.
fn expressionAt(analysis: *const emerald.Analysis, file: u32, offset: u32) ?Found {
    var best: ?Found = null;
    var iterator = analysis.checked.expression_types.iterator();
    while (iterator.next()) |entry| {
        const info = entry.value_ptr.*;
        if (info.file != file) continue;
        const expr = entry.key_ptr.*;
        const span = expr.span;
        if (offset < span.start or offset > span.end) continue;
        if (best == null or span.len() < best.?.span.len()) best = .{ .span = span, .type = info.type, .expression = expr };
    }
    return best;
}

// Go to definition.
//
// `findAssignmentInStatement`, `findTypeInStatement`, and `findDeclNameInStatement`
// below walk the statement tree, descending into every block a statement owns
// (loop bodies, `try`/`catch`/`finally`, a `case` arm's block form) — the same
// set `Resolver`'s own fact-gathering walks. They do not descend into an
// expression looking for a lambda literal's own block body, so a declaration,
// assignment, or type annotation written inside a lambda stays unreachable by
// go to definition for now, same as several other conservative spots in the
// capture/definite-assignment analysis (see `docs/handoff.md`'s rough edges).

fn onDefinition(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, id: std.json.Value, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, null);
        return;
    };

    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);

    var analysis = (try emerald.analyzeProject(gpa, &loaded.project)) orelse {
        try respond(gpa, out, id, null);
        return;
    };
    defer analysis.deinit(gpa);

    const source = &loaded.project.files[loaded.index].source;
    const offset = offsetFromPosition(source, position);
    const target = (try definitionAt(gpa, &analysis, loaded.index, offset)) orelse {
        try respond(gpa, out, id, null);
        return;
    };

    // Prelude declarations are embedded in the binary and have no file on disk.
    if (target.file >= loaded.project.files.len) {
        try respond(gpa, out, id, null);
        return;
    }

    const target_file = &loaded.project.files[target.file];
    const target_uri = if (target.file == loaded.index)
        try gpa.dupe(u8, uri)
    else
        try pathToUri(gpa, target_file.source.path);
    defer gpa.free(target_uri);

    try respond(gpa, out, id, Location{
        .uri = target_uri,
        .range = lspRange(&target_file.source, target.span),
    });
}

/// Finds the declaration target of whatever symbol is at `offset` in `file`:
/// an identifier, a member access, an assignment destination, a type annotation,
/// or a declaration name itself.
fn definitionAt(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, file: u32, offset: u32) !?Resolver.Target {
    // 1. Innermost expression at cursor.
    if (expressionAt(analysis, file, offset)) |found| {
        const expr = found.expression;
        if (expr.data == .name) {
            if (analysis.resolved.facts.expression_targets.get(expr)) |target| return target;
        } else if (expr.data == .member) {
            const member = expr.data.member;
            if (offset >= member.name_span.start and offset <= member.name_span.end) {
                if (try memberDefinition(gpa, analysis, file, expr)) |target| return target;
            }
        } else if (expr.data == .call) {
            // `Checker.typeOfCall` resolves a call's callee through
            // `referenceOf`/`self.find`, never through `typeOf`, so the callee
            // itself has no entry of its own in `expression_types` — only the
            // call as a whole does. `expressionAt` above lands on the call, and
            // a click on the plain function or constructor name it calls
            // (`Point(1, 2)`, `Shapes.area(3)`) has to be unwrapped from here.
            const callee = expr.data.call.callee;
            if (offset >= callee.span.start and offset <= callee.span.end) {
                if (callee.data == .name) {
                    if (analysis.resolved.facts.expression_targets.get(callee)) |target| return target;
                } else if (callee.data == .member) {
                    const member = callee.data.member;
                    if (offset >= member.name_span.start and offset <= member.name_span.end) {
                        if (try memberDefinition(gpa, analysis, file, callee)) |target| return target;
                    }
                }
            }
        }
    }

    // 2. Assignment destination name.
    if (assignmentTargetAt(analysis, file, offset)) |target| return target;

    // 3. Written TypeExpression.
    if (typeExpressionTargetAt(analysis, file, offset)) |target| return target;

    // 4. Declaration name itself.
    if (declarationNameAt(analysis, file, offset)) |target| return target;

    return null;
}

fn memberDefinition(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, file: u32, expr: *const Ast.Expression) !?Resolver.Target {
    const member = expr.data.member;

    // A namespace-qualified reference (e.g. `Shapes.area` or `Shapes.Circle`).
    if (analysis.resolved.facts.qualified.get(expr)) |key| {
        if (analysis.resolved.facts.declarations.get(key)) |target| return target;
    }

    // A method call recorded by the checker.
    if (analysis.checked.method_calls.get(expr)) |key| {
        if (analysis.resolved.facts.declarations.get(key)) |target| return target;
    }

    // A super member read.
    if (analysis.checked.super_members.get(expr)) |key| {
        if (analysis.resolved.facts.declarations.get(key)) |target| return target;
    }

    // An instance field or property read on a known struct/class type.
    // `optional` (Type.zig) is a flag alongside `kind`/`user`, not a wrapping
    // kind, so `T?`'s member access reads `user` exactly as `T`'s does.
    if (analysis.checked.expression_types.get(member.base)) |base_info| {
        const base_type = base_info.type;
        if (base_type.kind == .struct_value and base_type.user != null) {
            if (try findMemberInHierarchy(gpa, analysis, base_type.user.?.name, member.name)) |target| return target;
        }
    }

    // A type-level member access (e.g. `Direction.north` or `Player.count`).
    if (member.base.data == .name) {
        const base_name = member.base.data.name;
        const base_key = analysis.resolved.facts.keyFor(file, base_name) orelse base_name;
        if (try findMemberInHierarchy(gpa, analysis, base_key, member.name)) |target| return target;
    }

    return null;
}

/// Walks `start_type_key`'s base chain, then its adopted traits, for a member
/// named `member_name` — same key shape as `Resolver.methodKey`, built with
/// `gpa` rather than a fixed buffer, since a namespaced type name plus a
/// descriptive member name is not bounded the way the resolver's own arena
/// allocation isn't either.
fn findMemberInHierarchy(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, start_type_key: []const u8, member_name: []const u8) !?Resolver.Target {
    var type_key = start_type_key;
    while (true) {
        const key = try Resolver.methodKey(gpa, type_key, member_name);
        defer gpa.free(key);
        if (analysis.resolved.facts.declarations.get(key)) |t| return t;

        if (analysis.resolved.facts.bases.get(type_key)) |base_key| {
            type_key = base_key;
        } else break;
    }

    if (analysis.resolved.facts.adopted.get(start_type_key)) |traits| {
        for (traits) |trait_key| {
            const key = try Resolver.methodKey(gpa, trait_key, member_name);
            defer gpa.free(key);
            if (analysis.resolved.facts.declarations.get(key)) |t| return t;
        }
    }
    return null;
}

fn assignmentTargetAt(analysis: *const emerald.Analysis, file: u32, offset: u32) ?Resolver.Target {
    if (file >= analysis.parsed.len) return null;
    return findAssignmentInStatements(analysis.parsed[file].program.statements, file, offset, &analysis.resolved.facts.assignment_targets);
}

fn findAssignmentInStatements(statements: []const Ast.Statement, file: u32, offset: u32, targets: *const std.AutoHashMapUnmanaged(Resolver.Site, Resolver.Target)) ?Resolver.Target {
    for (statements) |statement| {
        if (findAssignmentInStatement(statement, file, offset, targets)) |target| return target;
    }
    return null;
}

fn findAssignmentInStatement(statement: Ast.Statement, file: u32, offset: u32, targets: *const std.AutoHashMapUnmanaged(Resolver.Site, Resolver.Target)) ?Resolver.Target {
    switch (statement.data) {
        .assignment => |a| {
            if (offset >= a.name_span.start and offset <= a.name_span.end) {
                return targets.get(.{ .file = file, .start = a.name_span.start });
            }
        },
        .destructuring_assignment => |da| {
            for (da.pattern.names) |name| {
                if (offset >= name.span.start and offset <= name.span.end) {
                    return targets.get(.{ .file = file, .start = name.span.start });
                }
            }
        },
        .conditional => |c| {
            if (findAssignmentInStatements(c.then_block.statements, file, offset, targets)) |target| return target;
            if (c.otherwise) |other| switch (other) {
                .block => |b| if (findAssignmentInStatements(b.statements, file, offset, targets)) |target| return target,
                .chained => |s| if (findAssignmentInStatement(s.*, file, offset, targets)) |target| return target,
            };
        },
        .while_loop => |w| {
            if (findAssignmentInStatements(w.body.statements, file, offset, targets)) |target| return target;
        },
        .for_loop => |f| {
            if (findAssignmentInStatements(f.body.statements, file, offset, targets)) |target| return target;
        },
        .case_statement => |case| {
            for (case.arms) |arm| {
                if (arm.body == .block) {
                    if (findAssignmentInStatements(arm.body.block.statements, file, offset, targets)) |target| return target;
                }
            }
            if (case.otherwise) |otherwise| {
                if (otherwise == .block) {
                    if (findAssignmentInStatements(otherwise.block.statements, file, offset, targets)) |target| return target;
                }
            }
        },
        .try_statement => |t| {
            if (findAssignmentInStatements(t.body.statements, file, offset, targets)) |target| return target;
            for (t.catches) |c| {
                if (findAssignmentInStatements(c.body.statements, file, offset, targets)) |target| return target;
            }
            if (t.finally_block) |fb| {
                if (findAssignmentInStatements(fb.statements, file, offset, targets)) |target| return target;
            }
        },
        .function_declaration => |f| {
            if (findAssignmentInStatements(f.body.statements, file, offset, targets)) |target| return target;
        },
        .struct_declaration => |s| {
            if (s.constructor) |c| {
                if (findAssignmentInStatements(c.body.statements, file, offset, targets)) |target| return target;
            }
            for (s.methods) |m| {
                if (findAssignmentInStatements(m.body.statements, file, offset, targets)) |target| return target;
            }
            for (s.properties) |p| {
                if (findAssignmentInStatements(p.getter.body.statements, file, offset, targets)) |target| return target;
                if (p.setter) |setter| {
                    if (findAssignmentInStatements(setter.body.statements, file, offset, targets)) |target| return target;
                }
            }
            for (s.type_functions) |tf| {
                if (findAssignmentInStatements(tf.declaration.body.statements, file, offset, targets)) |target| return target;
            }
        },
        else => {},
    }
    return null;
}

fn typeExpressionTargetAt(analysis: *const emerald.Analysis, file: u32, offset: u32) ?Resolver.Target {
    if (file >= analysis.parsed.len) return null;
    return findTypeInStatements(analysis.parsed[file].program.statements, file, offset, analysis);
}

fn checkTypeExpr(type_expr: Ast.TypeExpression, file: u32, offset: u32, analysis: *const emerald.Analysis) ?Resolver.Target {
    if (offset < type_expr.span.start or offset > type_expr.span.end) return null;

    if (type_expr.element) |elem| {
        if (checkTypeExpr(elem.*, file, offset, analysis)) |t| return t;
    }
    if (type_expr.key) |k| {
        if (checkTypeExpr(k.*, file, offset, analysis)) |t| return t;
    }
    if (type_expr.positions) |positions| {
        for (positions) |pos| {
            if (checkTypeExpr(pos, file, offset, analysis)) |t| return t;
        }
    }
    if (type_expr.signature) |sig| {
        for (sig.parameters) |param| {
            if (checkTypeExpr(param, file, offset, analysis)) |t| return t;
        }
        if (sig.result) |res| {
            if (checkTypeExpr(res.*, file, offset, analysis)) |t| return t;
        }
    }

    if (type_expr.name.len > 0) {
        const type_key = analysis.resolved.facts.keyFor(file, type_expr.name) orelse type_expr.name;
        if (analysis.resolved.facts.declarations.get(type_key)) |target| return target;
        if (analysis.resolved.facts.namespaceAliasFor(file, type_expr.name)) |alias| {
            if (analysis.resolved.facts.declarations.get(alias)) |target| return target;
        }
    }
    return null;
}

fn findTypeInStatements(statements: []const Ast.Statement, file: u32, offset: u32, analysis: *const emerald.Analysis) ?Resolver.Target {
    for (statements) |statement| {
        if (findTypeInStatement(statement, file, offset, analysis)) |target| return target;
    }
    return null;
}

fn findTypeInStatement(statement: Ast.Statement, file: u32, offset: u32, analysis: *const emerald.Analysis) ?Resolver.Target {
    switch (statement.data) {
        .declaration => |d| {
            if (d.annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
        },
        .destructuring => |d| {
            if (d.annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
        },
        .function_declaration => |f| {
            for (f.parameters) |p| if (checkTypeExpr(p.annotation, file, offset, analysis)) |t| return t;
            if (f.return_annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
            if (findTypeInStatements(f.body.statements, file, offset, analysis)) |t| return t;
        },
        .struct_declaration => |s| {
            if (s.base) |base| if (checkTypeExpr(base, file, offset, analysis)) |t| return t;
            for (s.traits) |tr| if (checkTypeExpr(tr, file, offset, analysis)) |t| return t;
            for (s.fields) |f| if (checkTypeExpr(f.annotation, file, offset, analysis)) |t| return t;
            for (s.properties) |p| if (checkTypeExpr(p.annotation, file, offset, analysis)) |t| return t;
            if (s.constructor) |c| {
                for (c.parameters) |p| if (checkTypeExpr(p.annotation, file, offset, analysis)) |t| return t;
                if (findTypeInStatements(c.body.statements, file, offset, analysis)) |t| return t;
            }
            for (s.methods) |m| {
                for (m.parameters) |p| if (checkTypeExpr(p.annotation, file, offset, analysis)) |t| return t;
                if (m.return_annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
                if (findTypeInStatements(m.body.statements, file, offset, analysis)) |t| return t;
            }
            for (s.type_functions) |tf| {
                for (tf.declaration.parameters) |p| if (checkTypeExpr(p.annotation, file, offset, analysis)) |t| return t;
                if (tf.declaration.return_annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
                if (findTypeInStatements(tf.declaration.body.statements, file, offset, analysis)) |t| return t;
            }
            for (s.type_fields) |tf| {
                if (tf.annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
            }
        },
        .conditional => |c| {
            if (findTypeInStatements(c.then_block.statements, file, offset, analysis)) |t| return t;
            if (c.otherwise) |other| switch (other) {
                .block => |b| if (findTypeInStatements(b.statements, file, offset, analysis)) |t| return t,
                .chained => |s| if (findTypeInStatement(s.*, file, offset, analysis)) |t| return t,
            };
        },
        .while_loop => |w| {
            if (findTypeInStatements(w.body.statements, file, offset, analysis)) |t| return t;
        },
        .for_loop => |f| {
            if (findTypeInStatements(f.body.statements, file, offset, analysis)) |t| return t;
        },
        .case_statement => |case| {
            for (case.arms) |arm| {
                if (arm.body == .block) {
                    if (findTypeInStatements(arm.body.block.statements, file, offset, analysis)) |t| return t;
                }
            }
            if (case.otherwise) |otherwise| {
                if (otherwise == .block) {
                    if (findTypeInStatements(otherwise.block.statements, file, offset, analysis)) |t| return t;
                }
            }
        },
        .try_statement => |try_stmt| {
            if (findTypeInStatements(try_stmt.body.statements, file, offset, analysis)) |target| return target;
            for (try_stmt.catches) |c| {
                if (c.annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |target| return target;
                if (findTypeInStatements(c.body.statements, file, offset, analysis)) |target| return target;
            }
            if (try_stmt.finally_block) |fb| {
                if (findTypeInStatements(fb.statements, file, offset, analysis)) |target| return target;
            }
        },
        else => {},
    }
    return null;
}

fn declarationNameAt(analysis: *const emerald.Analysis, file: u32, offset: u32) ?Resolver.Target {
    if (file >= analysis.parsed.len) return null;
    return findDeclNameInStatements(analysis.parsed[file].program.statements, file, offset);
}

fn findDeclNameInStatements(statements: []const Ast.Statement, file: u32, offset: u32) ?Resolver.Target {
    for (statements) |statement| {
        if (findDeclNameInStatement(statement, file, offset)) |t| return t;
    }
    return null;
}

fn findDeclNameInStatement(statement: Ast.Statement, file: u32, offset: u32) ?Resolver.Target {
    switch (statement.data) {
        .declaration => |d| {
            if (offset >= d.name_span.start and offset <= d.name_span.end) return .{ .file = file, .span = d.name_span };
        },
        .destructuring => |d| {
            for (d.pattern.names) |name| {
                if (offset >= name.span.start and offset <= name.span.end) return .{ .file = file, .span = name.span };
            }
        },
        .function_declaration => |f| {
            if (offset >= f.name_span.start and offset <= f.name_span.end) return .{ .file = file, .span = f.name_span };
            for (f.parameters) |p| {
                if (offset >= p.name_span.start and offset <= p.name_span.end) return .{ .file = file, .span = p.name_span };
            }
            if (findDeclNameInStatements(f.body.statements, file, offset)) |t| return t;
        },
        .struct_declaration => |s| {
            if (offset >= s.name_span.start and offset <= s.name_span.end) return .{ .file = file, .span = s.name_span };
            for (s.fields) |f| {
                if (offset >= f.name_span.start and offset <= f.name_span.end) return .{ .file = file, .span = f.name_span };
            }
            if (s.constructor) |c| {
                if (offset >= c.keyword_span.start and offset <= c.keyword_span.end) return .{ .file = file, .span = c.keyword_span };
                for (c.parameters) |p| {
                    if (offset >= p.name_span.start and offset <= p.name_span.end) return .{ .file = file, .span = p.name_span };
                }
                if (findDeclNameInStatements(c.body.statements, file, offset)) |t| return t;
            }
            for (s.methods) |m| {
                if (offset >= m.name_span.start and offset <= m.name_span.end) return .{ .file = file, .span = m.name_span };
                for (m.parameters) |p| {
                    if (offset >= p.name_span.start and offset <= p.name_span.end) return .{ .file = file, .span = p.name_span };
                }
                if (findDeclNameInStatements(m.body.statements, file, offset)) |t| return t;
            }
            for (s.properties) |p| {
                if (offset >= p.name_span.start and offset <= p.name_span.end) return .{ .file = file, .span = p.name_span };
                if (findDeclNameInStatements(p.getter.body.statements, file, offset)) |t| return t;
                if (p.setter) |setter| {
                    if (findDeclNameInStatements(setter.body.statements, file, offset)) |t| return t;
                }
            }
            for (s.type_functions) |tf| {
                if (offset >= tf.member_span.start and offset <= tf.member_span.end) return .{ .file = file, .span = tf.member_span };
                for (tf.declaration.parameters) |p| {
                    if (offset >= p.name_span.start and offset <= p.name_span.end) return .{ .file = file, .span = p.name_span };
                }
                if (findDeclNameInStatements(tf.declaration.body.statements, file, offset)) |t| return t;
            }
            for (s.type_fields) |tf| {
                if (offset >= tf.name_span.start and offset <= tf.name_span.end) return .{ .file = file, .span = tf.name_span };
            }
        },
        .conditional => |c| {
            if (findDeclNameInStatements(c.then_block.statements, file, offset)) |t| return t;
            if (c.otherwise) |other| switch (other) {
                .block => |b| if (findDeclNameInStatements(b.statements, file, offset)) |t| return t,
                .chained => |s| if (findDeclNameInStatement(s.*, file, offset)) |t| return t,
            };
        },
        .while_loop => |w| {
            if (findDeclNameInStatements(w.body.statements, file, offset)) |t| return t;
        },
        .for_loop => |f| {
            if (offset >= f.name_span.start and offset <= f.name_span.end) return .{ .file = file, .span = f.name_span };
            if (f.pattern) |pat| {
                for (pat.names) |name| {
                    if (offset >= name.span.start and offset <= name.span.end) return .{ .file = file, .span = name.span };
                }
            }
            if (findDeclNameInStatements(f.body.statements, file, offset)) |t| return t;
        },
        .case_statement => |case| {
            for (case.arms) |arm| {
                if (arm.body == .block) {
                    if (findDeclNameInStatements(arm.body.block.statements, file, offset)) |t| return t;
                }
            }
            if (case.otherwise) |otherwise| {
                if (otherwise == .block) {
                    if (findDeclNameInStatements(otherwise.block.statements, file, offset)) |t| return t;
                }
            }
        },
        .try_statement => |try_stmt| {
            if (findDeclNameInStatements(try_stmt.body.statements, file, offset)) |target| return target;
            for (try_stmt.catches) |c| {
                if (offset >= c.name_span.start and offset <= c.name_span.end) return .{ .file = file, .span = c.name_span };
                if (findDeclNameInStatements(c.body.statements, file, offset)) |target| return target;
            }
            if (try_stmt.finally_block) |fb| {
                if (findDeclNameInStatements(fb.statements, file, offset)) |target| return target;
            }
        },
        else => {},
    }
    return null;
}

// Find references.
//
// `definitionAt` above answers "what does the cursor point to?" with a single
// `Resolver.Target` — a declaration's own file and name span, the same
// whether the cursor sits on a read, a write, or the declaration itself.
// Find references answers the opposite question, "what points to this
// declaration?", by visiting every expression and declaration site in every
// file of the project and keeping the ones whose own resolved target is the
// same site. Unlike `definitionAt`'s handful of narrow, point-query walkers
// (built to stop at the first match nearest one offset), this needs every
// match anywhere, so it is one ordinary recursive descent through the whole
// statement and expression tree — which, as a side effect, reaches into a
// lambda's own block body, the one place `definitionAt`'s narrower walkers
// still cannot (see this file's other rough edges).

fn onReferences(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, include_declaration: bool, id: std.json.Value, out: *std.Io.Writer) !void {
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, null);
        return;
    };

    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);

    var analysis = (try emerald.analyzeProject(gpa, &loaded.project)) orelse {
        try respond(gpa, out, id, null);
        return;
    };
    defer analysis.deinit(gpa);

    const source = &loaded.project.files[loaded.index].source;
    const offset = offsetFromPosition(source, position);
    const target = (try definitionAt(gpa, &analysis, loaded.index, offset)) orelse {
        try respond(gpa, out, id, null);
        return;
    };
    // Prelude declarations are embedded in the binary and have no file on
    // disk, exactly `onDefinition`'s own reason for the same check.
    if (target.file >= loaded.project.files.len) {
        try respond(gpa, out, id, null);
        return;
    }

    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    if (include_declaration) try sites.append(gpa, target);
    for (analysis.parsed, 0..) |parsed, file_index| {
        try collectReferencesInStatements(gpa, &analysis, target, @intCast(file_index), parsed.program.statements, &sites);
    }

    var locations: std.ArrayList(Location) = .empty;
    defer {
        for (locations.items) |location| gpa.free(location.uri);
        locations.deinit(gpa);
    }
    for (sites.items) |site| {
        const site_file = &loaded.project.files[site.file];
        const site_uri = if (site.file == loaded.index)
            try gpa.dupe(u8, uri)
        else
            try pathToUri(gpa, site_file.source.path);
        try locations.append(gpa, .{ .uri = site_uri, .range = lspRange(&site_file.source, site.span) });
    }

    try respond(gpa, out, id, locations.items);
}

fn targetEql(a: Resolver.Target, b: Resolver.Target) bool {
    return a.file == b.file and a.span.start == b.span.start and a.span.end == b.span.end;
}

fn collectReferencesInStatements(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    statements: []const Ast.Statement,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    for (statements) |statement| try collectReferencesInStatement(gpa, analysis, target, file, statement, out);
}

fn collectReferencesInStatement(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    statement: Ast.Statement,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    switch (statement.data) {
        .expression => |e| try collectReferencesInExpression(gpa, analysis, target, file, e, out),
        .declaration => |d| {
            if (d.annotation) |ann| try collectReferencesInTypeExpression(gpa, analysis, target, file, ann, out);
            if (d.initializer) |init_expr| try collectReferencesInExpression(gpa, analysis, target, file, init_expr, out);
        },
        .assignment => |a| {
            if (analysis.resolved.facts.assignment_targets.get(.{ .file = file, .start = a.name_span.start })) |found| {
                if (targetEql(found, target)) try out.append(gpa, .{ .file = file, .span = a.name_span });
            }
            for (a.steps) |step| switch (step) {
                .index => |idx| try collectReferencesInExpression(gpa, analysis, target, file, idx, out),
                .field => {},
            };
            try collectReferencesInExpression(gpa, analysis, target, file, a.value, out);
        },
        .conditional => |c| {
            try collectReferencesInExpression(gpa, analysis, target, file, c.condition, out);
            try collectReferencesInStatements(gpa, analysis, target, file, c.then_block.statements, out);
            if (c.otherwise) |other| switch (other) {
                .block => |b| try collectReferencesInStatements(gpa, analysis, target, file, b.statements, out),
                .chained => |s| try collectReferencesInStatement(gpa, analysis, target, file, s.*, out),
            };
        },
        .while_loop => |w| {
            try collectReferencesInExpression(gpa, analysis, target, file, w.condition, out);
            try collectReferencesInStatements(gpa, analysis, target, file, w.body.statements, out);
        },
        .for_loop => |f| {
            try collectReferencesInExpression(gpa, analysis, target, file, f.iterable, out);
            try collectReferencesInStatements(gpa, analysis, target, file, f.body.statements, out);
        },
        .break_statement, .continue_statement => {},
        .function_declaration => |f| try collectReferencesInFunction(gpa, analysis, target, file, f, out),
        .struct_declaration => |s| try collectReferencesInStruct(gpa, analysis, target, file, s, out),
        .return_statement => |r| if (r.value) |v| try collectReferencesInExpression(gpa, analysis, target, file, v, out),
        .raise_statement => |r| if (r.value) |v| try collectReferencesInExpression(gpa, analysis, target, file, v, out),
        .try_statement => |t| {
            try collectReferencesInStatements(gpa, analysis, target, file, t.body.statements, out);
            for (t.catches) |c| {
                if (c.annotation) |ann| try collectReferencesInTypeExpression(gpa, analysis, target, file, ann, out);
                try collectReferencesInStatements(gpa, analysis, target, file, c.body.statements, out);
            }
            if (t.finally_block) |fb| try collectReferencesInStatements(gpa, analysis, target, file, fb.statements, out);
        },
        .assert_statement => |a| {
            try collectReferencesInExpression(gpa, analysis, target, file, a.condition, out);
            if (a.message) |m| try collectReferencesInExpression(gpa, analysis, target, file, m, out);
        },
        .destructuring => |d| {
            if (d.annotation) |ann| try collectReferencesInTypeExpression(gpa, analysis, target, file, ann, out);
            try collectReferencesInExpression(gpa, analysis, target, file, d.initializer, out);
        },
        .destructuring_assignment => |da| {
            for (da.pattern.names) |name| {
                if (analysis.resolved.facts.assignment_targets.get(.{ .file = file, .start = name.span.start })) |found| {
                    if (targetEql(found, target)) try out.append(gpa, .{ .file = file, .span = name.span });
                }
            }
            try collectReferencesInExpression(gpa, analysis, target, file, da.value, out);
        },
        .case_statement => |case| try collectReferencesInCase(gpa, analysis, target, file, case.*, out),
    }
}

fn collectReferencesInFunction(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    f: Ast.FunctionDeclaration,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    for (f.parameters) |p| {
        try collectReferencesInTypeExpression(gpa, analysis, target, file, p.annotation, out);
        if (p.default) |d| try collectReferencesInExpression(gpa, analysis, target, file, d, out);
    }
    if (f.return_annotation) |ann| try collectReferencesInTypeExpression(gpa, analysis, target, file, ann, out);
    try collectReferencesInStatements(gpa, analysis, target, file, f.body.statements, out);
}

fn collectReferencesInStruct(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    s: Ast.StructDeclaration,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    if (s.base) |base| try collectReferencesInTypeExpression(gpa, analysis, target, file, base, out);
    for (s.traits) |tr| try collectReferencesInTypeExpression(gpa, analysis, target, file, tr, out);
    for (s.fields) |field| {
        try collectReferencesInTypeExpression(gpa, analysis, target, file, field.annotation, out);
        if (field.default) |d| try collectReferencesInExpression(gpa, analysis, target, file, d, out);
    }
    for (s.properties) |p| {
        try collectReferencesInTypeExpression(gpa, analysis, target, file, p.annotation, out);
        try collectReferencesInFunction(gpa, analysis, target, file, p.getter, out);
        if (p.setter) |setter| try collectReferencesInFunction(gpa, analysis, target, file, setter, out);
    }
    if (s.constructor) |c| {
        for (c.parameters) |p| {
            try collectReferencesInTypeExpression(gpa, analysis, target, file, p.annotation, out);
            if (p.default) |d| try collectReferencesInExpression(gpa, analysis, target, file, d, out);
        }
        try collectReferencesInStatements(gpa, analysis, target, file, c.body.statements, out);
    }
    for (s.methods) |m| try collectReferencesInFunction(gpa, analysis, target, file, m, out);
    for (s.type_functions) |tf| try collectReferencesInFunction(gpa, analysis, target, file, tf.declaration, out);
    for (s.type_fields) |tf| {
        if (tf.annotation) |ann| try collectReferencesInTypeExpression(gpa, analysis, target, file, ann, out);
        try collectReferencesInExpression(gpa, analysis, target, file, tf.initializer, out);
    }
}

fn collectReferencesInCase(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    case: Ast.Case,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    if (case.subject) |subject| try collectReferencesInExpression(gpa, analysis, target, file, subject, out);
    for (case.arms) |arm| {
        for (arm.alternatives) |alt| try collectReferencesInExpression(gpa, analysis, target, file, alt, out);
        switch (arm.body) {
            .block => |b| try collectReferencesInStatements(gpa, analysis, target, file, b.statements, out),
            .value => |v| try collectReferencesInExpression(gpa, analysis, target, file, v, out),
        }
    }
    if (case.otherwise) |otherwise| switch (otherwise) {
        .block => |b| try collectReferencesInStatements(gpa, analysis, target, file, b.statements, out),
        .value => |v| try collectReferencesInExpression(gpa, analysis, target, file, v, out),
    };
}

/// Mirrors `checkTypeExpr`'s recursion exactly, but collects every match
/// instead of stopping at the first one that contains a byte offset.
fn collectReferencesInTypeExpression(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    type_expr: Ast.TypeExpression,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    if (type_expr.element) |elem| try collectReferencesInTypeExpression(gpa, analysis, target, file, elem.*, out);
    if (type_expr.key) |k| try collectReferencesInTypeExpression(gpa, analysis, target, file, k.*, out);
    if (type_expr.positions) |positions| {
        for (positions) |pos| try collectReferencesInTypeExpression(gpa, analysis, target, file, pos, out);
    }
    if (type_expr.signature) |sig| {
        for (sig.parameters) |param| try collectReferencesInTypeExpression(gpa, analysis, target, file, param, out);
        if (sig.result) |res| try collectReferencesInTypeExpression(gpa, analysis, target, file, res.*, out);
    }

    if (type_expr.name.len > 0) {
        const type_key = analysis.resolved.facts.keyFor(file, type_expr.name) orelse type_expr.name;
        var found = analysis.resolved.facts.declarations.get(type_key);
        if (found == null) {
            if (analysis.resolved.facts.namespaceAliasFor(file, type_expr.name)) |alias| {
                found = analysis.resolved.facts.declarations.get(alias);
            }
        }
        if (found) |f| if (targetEql(f, target)) try out.append(gpa, .{ .file = file, .span = type_expr.span });
    }
}

fn collectReferencesInExpression(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    target: Resolver.Target,
    file: u32,
    expr: *const Ast.Expression,
    out: *std.ArrayList(Resolver.Target),
) std.mem.Allocator.Error!void {
    switch (expr.data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .enum_value, .string_literal => {},
        .name => {
            if (analysis.resolved.facts.expression_targets.get(expr)) |found| {
                if (targetEql(found, target)) try out.append(gpa, .{ .file = file, .span = expr.span });
            }
        },
        .member => |member| {
            if (try memberDefinition(gpa, analysis, file, expr)) |found| {
                if (targetEql(found, target)) try out.append(gpa, .{ .file = file, .span = member.name_span });
            }
            try collectReferencesInExpression(gpa, analysis, target, file, member.base, out);
        },
        .unary => |u| try collectReferencesInExpression(gpa, analysis, target, file, u.operand, out),
        .binary => |b| {
            try collectReferencesInExpression(gpa, analysis, target, file, b.left, out);
            try collectReferencesInExpression(gpa, analysis, target, file, b.right, out);
        },
        .logical => |l| {
            try collectReferencesInExpression(gpa, analysis, target, file, l.left, out);
            try collectReferencesInExpression(gpa, analysis, target, file, l.right, out);
        },
        .comparison => |c| for (c.operands) |operand| try collectReferencesInExpression(gpa, analysis, target, file, operand, out),
        .call => |call| {
            try collectReferencesInExpression(gpa, analysis, target, file, call.callee, out);
            for (call.arguments) |arg| try collectReferencesInExpression(gpa, analysis, target, file, arg, out);
        },
        .range => |r| {
            try collectReferencesInExpression(gpa, analysis, target, file, r.start, out);
            try collectReferencesInExpression(gpa, analysis, target, file, r.end, out);
        },
        .interpolation => |parts| for (parts) |part| switch (part) {
            .text => {},
            .expression => |e| try collectReferencesInExpression(gpa, analysis, target, file, e, out),
        },
        .list_literal, .tuple_literal => |items| for (items) |item| try collectReferencesInExpression(gpa, analysis, target, file, item, out),
        .dictionary_literal => |entries| for (entries) |entry| {
            try collectReferencesInExpression(gpa, analysis, target, file, entry.key, out);
            try collectReferencesInExpression(gpa, analysis, target, file, entry.value, out);
        },
        .index => |i| {
            try collectReferencesInExpression(gpa, analysis, target, file, i.base, out);
            try collectReferencesInExpression(gpa, analysis, target, file, i.index, out);
        },
        .slice => |s| {
            try collectReferencesInExpression(gpa, analysis, target, file, s.base, out);
            if (s.start) |start| try collectReferencesInExpression(gpa, analysis, target, file, start, out);
            if (s.end) |end| try collectReferencesInExpression(gpa, analysis, target, file, end, out);
        },
        .lambda => |lambda| switch (lambda.body) {
            .expression => |e| try collectReferencesInExpression(gpa, analysis, target, file, e, out),
            .block => |block| try collectReferencesInStatements(gpa, analysis, target, file, block.statements, out),
        },
        .case_expression => |case| try collectReferencesInCase(gpa, analysis, target, file, case.*, out),
        .type_test => |t| {
            try collectReferencesInExpression(gpa, analysis, target, file, t.value, out);
            try collectReferencesInTypeExpression(gpa, analysis, target, file, t.target, out);
        },
    }
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

test "offsetFromPosition is lspPosition's inverse, including astral scalars" {
    const gpa = testing.allocator;
    var source = try Source.init(gpa, "t.em", "a🎉b\nsecond line\n");
    defer source.deinit(gpa);

    // Every byte offset on the first line round-trips through a position.
    for ([_]u32{ 0, 1, 5, 6 }) |offset| {
        const position = lspPosition(&source, offset);
        try testing.expectEqual(offset, offsetFromPosition(&source, position));
    }
    // The second line, and a character count past its end clamps rather
    // than indexing out of range.
    try testing.expectEqual(@as(u32, 7), offsetFromPosition(&source, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(@as(u32, 18), offsetFromPosition(&source, .{ .line = 1, .character = 999 }));
}

test "uriToPath percent-decodes and strips a Windows drive letter's extra slash" {
    const gpa = testing.allocator;

    const plain = (try uriToPath(gpa, "file:///home/ada/greet.em")).?;
    defer gpa.free(plain);
    try testing.expectEqualStrings("/home/ada/greet.em", plain);

    const spaced = (try uriToPath(gpa, "file:///home/ada/my%20file.em")).?;
    defer gpa.free(spaced);
    try testing.expectEqualStrings("/home/ada/my file.em", spaced);

    const windows = (try uriToPath(gpa, "file:///C:/Users/ada/greet.em")).?;
    defer gpa.free(windows);
    try testing.expectEqualStrings("C:/Users/ada/greet.em", windows);

    try testing.expectEqual(@as(?[]u8, null), try uriToPath(gpa, "untitled:Untitled-1"));
}

test "expressionAt finds the innermost expression, not the outer one it nests in" {
    const gpa = testing.allocator;
    var source = try Source.init(gpa, "t.em", "var total = 5\nprint(total)\n");
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    // Offset 22 is the "total" read inside `print(total)`, which sits nested
    // inside the whole `print(total)` call — the call's own span also
    // contains that offset, so finding the smaller of the two is the point.
    const found = expressionAt(&analysis, 0, 22).?;
    try testing.expectEqual(Type.int, found.type);
    try testing.expectEqual(@as(u32, 5), found.span.len());

    try testing.expectEqual(@as(?Found, null), expressionAt(&analysis, 0, 999));
    try testing.expectEqual(@as(?Found, null), expressionAt(&analysis, 1, 22));
}

test "definitionAt jumps from a variable's read to its declaration" {
    const gpa = testing.allocator;
    const text = "var total = 5\nprint(total)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const use_offset: u32 = @intCast(std.mem.indexOf(u8, text, "total)").?);
    const target = (try definitionAt(gpa, &analysis, 0, use_offset)).?;
    try testing.expectEqual(@as(u32, 0), target.file);
    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "total =").?);
    try testing.expectEqual(decl_offset, target.span.start);
}

test "definitionAt jumps from a member access to the field it names" {
    const gpa = testing.allocator;
    const text = "struct Point {\n    var x: Int\n}\nconst p = Point(1)\nprint(p.x)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const use_offset: u32 = @intCast(std.mem.indexOf(u8, text, "p.x)").? + 2);
    const target = (try definitionAt(gpa, &analysis, 0, use_offset)).?;
    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "x: Int").?);
    try testing.expectEqual(decl_offset, target.span.start);
}

test "definitionAt jumps from a written type annotation to the struct it names" {
    const gpa = testing.allocator;
    const text = "struct Circle {}\nvar c: Circle = Circle()\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const use_offset: u32 = @intCast(std.mem.indexOf(u8, text, ": Circle =").? + 2);
    const target = (try definitionAt(gpa, &analysis, 0, use_offset)).?;
    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "struct Circle").? + "struct ".len);
    try testing.expectEqual(decl_offset, target.span.start);
}

test "definitionAt reaches an assignment inside a case arm's block" {
    // Regression test: `findAssignmentInStatement` originally had no
    // `.case_statement` branch, so this returned null even though
    // `Resolver`'s own fact-gathering walks into case arms fine.
    const gpa = testing.allocator;
    const text = "var x = 1\ncase 1 {\n    when 1 {\n        x = 2\n    }\n}\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const use_offset: u32 = @intCast(std.mem.indexOf(u8, text, "x = 2").?);
    const target = (try definitionAt(gpa, &analysis, 0, use_offset)).?;
    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "x = 1").?);
    try testing.expectEqual(decl_offset, target.span.start);
}

test "definitionAt jumps from a constructor call's own name to its struct" {
    // Regression test: the checker resolves a call's callee through
    // `referenceOf`, never `typeOf` (Checker.typeOfCall), so `expressionAt`
    // (which only knows what the checker gave a `Type`) lands on the whole
    // call rather than the callee, and a naive `expr.data == .name` check
    // in `definitionAt` never even sees the callee node.
    const gpa = testing.allocator;
    const text = "struct Point {\n    var x: Int\n}\nconst p = Point(1)\nprint(p)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const use_offset: u32 = @intCast(std.mem.indexOf(u8, text, "Point(1)").? + 1);
    const target = (try definitionAt(gpa, &analysis, 0, use_offset)).?;
    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "struct Point").? + "struct ".len);
    try testing.expectEqual(decl_offset, target.span.start);
}

test "collectReferencesInStatements finds every read of a variable, but not its declaration" {
    const gpa = testing.allocator;
    const text = "var total = 5\nprint(total)\nprint(total + 1)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "total =").?);
    const target = (try definitionAt(gpa, &analysis, 0, decl_offset)).?;

    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    try collectReferencesInStatements(gpa, &analysis, target, 0, analysis.parsed[0].program.statements, &sites);

    try testing.expectEqual(@as(usize, 2), sites.items.len);
    const first_use: u32 = @intCast(std.mem.indexOf(u8, text, "total)").?);
    const second_use: u32 = @intCast(std.mem.indexOf(u8, text, "total + 1").?);
    try testing.expectEqual(first_use, sites.items[0].span.start);
    try testing.expectEqual(second_use, sites.items[1].span.start);
}

test "collectReferencesInStatements finds both a struct's constructor call and its type annotation" {
    const gpa = testing.allocator;
    const text = "struct Point {\n    var x: Int\n}\nconst p = Point(1)\nvar q: Point = p\nprint(q)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, text, "struct Point").? + "struct ".len);
    const target = (try definitionAt(gpa, &analysis, 0, decl_offset)).?;

    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    try collectReferencesInStatements(gpa, &analysis, target, 0, analysis.parsed[0].program.statements, &sites);

    try testing.expectEqual(@as(usize, 2), sites.items.len);
    const call_offset: u32 = @intCast(std.mem.indexOf(u8, text, "Point(1)").?);
    const annotation_offset: u32 = @intCast(std.mem.indexOf(u8, text, ": Point =").? + 2);
    try testing.expectEqual(call_offset, sites.items[0].span.start);
    try testing.expectEqual(annotation_offset, sites.items[1].span.start);
}

test "collectReferencesInStatements finds a struct's use in a sibling file of the same project" {
    const gpa = testing.allocator;
    const main_text = "const c = Shapes.Circle(2.0)\nprint(c)\n";
    const shapes_text = "struct Circle {\n    var radius: Float\n}\n";
    var main_source = try Source.init(gpa, "main.em", main_text);
    defer main_source.deinit(gpa);
    var shapes_source = try Source.init(gpa, "shapes/circle.em", shapes_text);
    defer shapes_source.deinit(gpa);
    var files = [_]emerald.Project.File{
        .{ .source = main_source, .namespace = "", .entry = true },
        .{ .source = shapes_source, .namespace = "Shapes", .entry = false },
    };
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const decl_offset: u32 = @intCast(std.mem.indexOf(u8, shapes_text, "struct Circle").? + "struct ".len);
    const target = (try definitionAt(gpa, &analysis, 1, decl_offset)).?;
    try testing.expectEqual(@as(u32, 1), target.file);

    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    for (analysis.parsed, 0..) |parsed, file_index| {
        try collectReferencesInStatements(gpa, &analysis, target, @intCast(file_index), parsed.program.statements, &sites);
    }

    try testing.expectEqual(@as(usize, 1), sites.items.len);
    try testing.expectEqual(@as(u32, 0), sites.items[0].file);
    const use_offset: u32 = @intCast(std.mem.indexOf(u8, main_text, "Circle(2.0)").?);
    try testing.expectEqual(use_offset, sites.items[0].span.start);
}
