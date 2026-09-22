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
//! write, and type use whose own resolved site matches it.
//!
//! Rename is the fourth piece, directly on top: find references' own result
//! set (the declaration included), each site's span replaced by the new
//! name and grouped into one `TextEdit` array per file. `prepareRename`
//! reuses that same result set rather than a separate word-boundary guess:
//! whichever site contains the cursor is the range offered, so a client
//! never highlights more or less than a rename from there would actually
//! touch.
//!
//! Completion is the fifth and last piece, the one that needed a different
//! strategy rather than more of the same: an in-progress member access,
//! `foo.` or `foo.par`, does not merely lack a type the checker never
//! computed — it fails to *parse* at all, discarding its whole enclosing
//! statement (see the section below for why, and how a completion request
//! works around it without touching the shared parser). The same completion
//! pass also answers type-qualified and namespace members from resolver facts,
//! plus visible module-level names at a bare identifier.
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

fn respondError(gpa: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try writeMessage(gpa, out, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
}

fn respondMethodNotFound(gpa: std.mem.Allocator, out: *std.Io.Writer, id: std.json.Value) !void {
    try respondError(gpa, out, id, -32601, "method not found");
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
                .renameProvider = .{ .prepareProvider = true },
                .completionProvider = .{ .triggerCharacters = &[_][]const u8{"."} },
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
    if (std.mem.eql(u8, method, "textDocument/rename")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        const params_obj = params orelse return error.InvalidParams;
        const new_name = try stringField(params_obj, "newName");
        if (id) |request_id| try onRename(server, gpa, uri, position, new_name, request_id, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        if (id) |request_id| try onPrepareRename(server, gpa, uri, position, request_id, out);
        return false;
    }
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        const text_document = try objectField(params, "textDocument");
        const uri = try stringField(text_document, "uri");
        const position = try positionField(params);
        if (id) |request_id| try onCompletion(server, gpa, uri, position, request_id, out);
        return false;
    }

    // Anything else, and `$/cancelRequest`: a well-formed "not found" for a
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

    // §3.4/18.3: the canonical brace style is a per-project choice
    // (`emerald.toml`'s `brace_style`), so formatting a single open file
    // still goes through `loadDocument` to find the project it belongs to —
    // the same reason hover and everything after it needed it.
    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);
    const source = &loaded.project.files[loaded.index].source;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokenized = try Lexer.tokenize(arena, source);
    const parsed = if (tokenized.diagnostics.len == 0) try Parser.parse(arena, source, tokenized.tokens) else null;

    // 18.3: refuses to rewrite a file it cannot parse safely — no edit at all.
    if (tokenized.diagnostics.len != 0 or parsed.?.diagnostics.len != 0) {
        try respond(gpa, out, id, @as([]const TextEdit, &.{}));
        return;
    }

    const formatted = try Formatter.print(arena, source, tokenized.tokens, parsed.?.program, loaded.project.brace_style);
    const whole_document = Source.Span{ .start = 0, .end = @intCast(document.text.items.len) };
    const edit = TextEdit{ .range = lspRange(source, whole_document), .newText = formatted };
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
// below mirror Resolver's complete statement-and-expression walk. In particular,
// a lambda is an expression but can own a block, declarations, assignments, and
// parameter annotations of its own; each point-query walker descends through it.

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
        } else if (expr.data == .binary) {
            const binary = expr.data.binary;
            if (offset >= binary.operator_span.start and offset <= binary.operator_span.end) {
                if (analysis.checked.operator_calls.get(expr)) |key| {
                    if (analysis.resolved.facts.declarations.get(key)) |target| return target;
                }
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

/// True only for an arithmetic symbol whose binary expression selected an
/// annotated method. The symbol is useful navigation syntax, not an
/// identifier a rename can replace.
fn isAnnotatedOperatorAt(analysis: *const emerald.Analysis, file: u32, offset: u32) bool {
    const found = expressionAt(analysis, file, offset) orelse return false;
    if (found.expression.data != .binary) return false;
    const binary = found.expression.data.binary;
    return offset >= binary.operator_span.start and offset <= binary.operator_span.end and analysis.checked.operator_calls.contains(found.expression);
}

fn isOperatorTokenSpan(source: *const Source, span: Source.Span) bool {
    const start: usize = @intCast(span.start);
    const end: usize = @intCast(span.end);
    const text = source.text[start..end];
    return text.len == 1 and switch (text[0]) {
        '+', '-', '*', '/' => true,
        else => false,
    };
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
        .expression => |e| return findAssignmentInExpression(e, file, offset, targets),
        .declaration => |d| if (d.initializer) |e| return findAssignmentInExpression(e, file, offset, targets),
        .assignment => |a| {
            if (offset >= a.name_span.start and offset <= a.name_span.end) {
                return targets.get(.{ .file = file, .start = a.name_span.start });
            }
            for (a.steps) |step| if (step == .index) {
                if (findAssignmentInExpression(step.index, file, offset, targets)) |target| return target;
            };
            return findAssignmentInExpression(a.value, file, offset, targets);
        },
        .destructuring_assignment => |da| {
            for (da.pattern.names) |name| {
                if (offset >= name.span.start and offset <= name.span.end) {
                    return targets.get(.{ .file = file, .start = name.span.start });
                }
            }
            return findAssignmentInExpression(da.value, file, offset, targets);
        },
        .conditional => |c| {
            if (findAssignmentInExpression(c.condition, file, offset, targets)) |target| return target;
            if (findAssignmentInStatements(c.then_block.statements, file, offset, targets)) |target| return target;
            if (c.otherwise) |other| switch (other) {
                .block => |b| if (findAssignmentInStatements(b.statements, file, offset, targets)) |target| return target,
                .chained => |s| if (findAssignmentInStatement(s.*, file, offset, targets)) |target| return target,
            };
        },
        .while_loop => |w| {
            if (findAssignmentInExpression(w.condition, file, offset, targets)) |target| return target;
            if (findAssignmentInStatements(w.body.statements, file, offset, targets)) |target| return target;
        },
        .for_loop => |f| {
            if (findAssignmentInExpression(f.iterable, file, offset, targets)) |target| return target;
            if (findAssignmentInStatements(f.body.statements, file, offset, targets)) |target| return target;
        },
        .case_statement => |case| {
            if (case.subject) |subject| if (findAssignmentInExpression(subject, file, offset, targets)) |target| return target;
            for (case.arms) |arm| {
                for (arm.alternatives) |alternative| if (findAssignmentInExpression(alternative, file, offset, targets)) |target| return target;
                if (arm.body == .block) {
                    if (findAssignmentInStatements(arm.body.block.statements, file, offset, targets)) |target| return target;
                } else if (findAssignmentInExpression(arm.body.value, file, offset, targets)) |target| return target;
            }
            if (case.otherwise) |otherwise| {
                if (otherwise == .block) {
                    if (findAssignmentInStatements(otherwise.block.statements, file, offset, targets)) |target| return target;
                } else if (findAssignmentInExpression(otherwise.value, file, offset, targets)) |target| return target;
            }
        },
        .return_statement => |r| if (r.value) |value| return findAssignmentInExpression(value, file, offset, targets),
        .raise_statement => |r| if (r.value) |value| return findAssignmentInExpression(value, file, offset, targets),
        .assert_statement => |a| {
            if (findAssignmentInExpression(a.condition, file, offset, targets)) |target| return target;
            if (a.message) |message| return findAssignmentInExpression(message, file, offset, targets);
        },
        .destructuring => |d| return findAssignmentInExpression(d.initializer, file, offset, targets),
        .function_declaration => |f| {
            for (f.parameters) |parameter| if (parameter.default) |value| {
                if (findAssignmentInExpression(value, file, offset, targets)) |target| return target;
            };
            if (findAssignmentInStatements(f.body.statements, file, offset, targets)) |target| return target;
        },
        .struct_declaration => |s| {
            for (s.fields) |field| if (field.default) |value| {
                if (findAssignmentInExpression(value, file, offset, targets)) |target| return target;
            };
            for (s.type_fields) |field| if (findAssignmentInExpression(field.initializer, file, offset, targets)) |target| return target;
            if (s.constructor) |constructor| {
                for (constructor.parameters) |parameter| if (parameter.default) |value| {
                    if (findAssignmentInExpression(value, file, offset, targets)) |target| return target;
                };
            }
            for (s.methods) |method| {
                for (method.parameters) |parameter| if (parameter.default) |value| {
                    if (findAssignmentInExpression(value, file, offset, targets)) |target| return target;
                };
            }
            for (s.type_functions) |function| {
                for (function.declaration.parameters) |parameter| if (parameter.default) |value| {
                    if (findAssignmentInExpression(value, file, offset, targets)) |target| return target;
                };
            }
            if (s.constructor) |constructor| if (findAssignmentInStatements(constructor.body.statements, file, offset, targets)) |target| return target;
            for (s.methods) |method| if (findAssignmentInStatements(method.body.statements, file, offset, targets)) |target| return target;
            for (s.properties) |property| {
                if (findAssignmentInStatements(property.getter.body.statements, file, offset, targets)) |target| return target;
                if (property.setter) |setter| if (findAssignmentInStatements(setter.body.statements, file, offset, targets)) |target| return target;
            }
            for (s.type_functions) |function| if (findAssignmentInStatements(function.declaration.body.statements, file, offset, targets)) |target| return target;
        },
        .try_statement => |t| {
            if (findAssignmentInStatements(t.body.statements, file, offset, targets)) |target| return target;
            for (t.catches) |c| if (findAssignmentInStatements(c.body.statements, file, offset, targets)) |target| return target;
            if (t.finally_block) |fb| if (findAssignmentInStatements(fb.statements, file, offset, targets)) |target| return target;
        },
        .break_statement, .continue_statement => {},
    }
    return null;
}

fn findAssignmentInExpression(expression: *const Ast.Expression, file: u32, offset: u32, targets: *const std.AutoHashMapUnmanaged(Resolver.Site, Resolver.Target)) ?Resolver.Target {
    if (offset < expression.span.start or offset > expression.span.end) return null;
    switch (expression.data) {
        .unary => |value| return findAssignmentInExpression(value.operand, file, offset, targets),
        .binary => |value| {
            if (findAssignmentInExpression(value.left, file, offset, targets)) |target| return target;
            return findAssignmentInExpression(value.right, file, offset, targets);
        },
        .logical => |value| {
            if (findAssignmentInExpression(value.left, file, offset, targets)) |target| return target;
            return findAssignmentInExpression(value.right, file, offset, targets);
        },
        .comparison => |value| for (value.operands) |operand| if (findAssignmentInExpression(operand, file, offset, targets)) |target| return target,
        .call => |value| {
            if (findAssignmentInExpression(value.callee, file, offset, targets)) |target| return target;
            for (value.arguments) |argument| if (findAssignmentInExpression(argument, file, offset, targets)) |target| return target;
        },
        .range => |value| {
            if (findAssignmentInExpression(value.start, file, offset, targets)) |target| return target;
            return findAssignmentInExpression(value.end, file, offset, targets);
        },
        .interpolation => |parts| for (parts) |part| if (part == .expression) if (findAssignmentInExpression(part.expression, file, offset, targets)) |target| return target,
        .list_literal, .tuple_literal => |items| for (items) |item| if (findAssignmentInExpression(item, file, offset, targets)) |target| return target,
        .dictionary_literal => |entries| for (entries) |entry| {
            if (findAssignmentInExpression(entry.key, file, offset, targets)) |target| return target;
            if (findAssignmentInExpression(entry.value, file, offset, targets)) |target| return target;
        },
        .index => |value| {
            if (findAssignmentInExpression(value.base, file, offset, targets)) |target| return target;
            return findAssignmentInExpression(value.index, file, offset, targets);
        },
        .slice => |value| {
            if (findAssignmentInExpression(value.base, file, offset, targets)) |target| return target;
            if (value.start) |start| if (findAssignmentInExpression(start, file, offset, targets)) |target| return target;
            if (value.end) |end| return findAssignmentInExpression(end, file, offset, targets);
        },
        .member => |value| return findAssignmentInExpression(value.base, file, offset, targets),
        .lambda => |lambda| switch (lambda.body) {
            .expression => |body| return findAssignmentInExpression(body, file, offset, targets),
            .block => |body| return findAssignmentInStatements(body.statements, file, offset, targets),
        },
        .case_expression => |case| {
            if (case.subject) |subject| if (findAssignmentInExpression(subject, file, offset, targets)) |target| return target;
            for (case.arms) |arm| {
                for (arm.alternatives) |alternative| if (findAssignmentInExpression(alternative, file, offset, targets)) |target| return target;
                switch (arm.body) {
                    .block => |body| if (findAssignmentInStatements(body.statements, file, offset, targets)) |target| return target,
                    .value => |body| if (findAssignmentInExpression(body, file, offset, targets)) |target| return target,
                }
            }
            if (case.otherwise) |otherwise| switch (otherwise) {
                .block => |body| return findAssignmentInStatements(body.statements, file, offset, targets),
                .value => |body| return findAssignmentInExpression(body, file, offset, targets),
            };
        },
        .type_test => |value| return findAssignmentInExpression(value.value, file, offset, targets),
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .enum_value, .string_literal => {},
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
        .expression => |expression| return findTypeInExpression(expression, file, offset, analysis),
        .declaration => |d| {
            if (d.annotation) |ann| if (checkTypeExpr(ann, file, offset, analysis)) |t| return t;
            if (d.initializer) |initializer| return findTypeInExpression(initializer, file, offset, analysis);
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

fn findTypeInExpression(expression: *const Ast.Expression, file: u32, offset: u32, analysis: *const emerald.Analysis) ?Resolver.Target {
    if (offset < expression.span.start or offset > expression.span.end) return null;
    switch (expression.data) {
        .unary => |value| return findTypeInExpression(value.operand, file, offset, analysis),
        .binary => |value| {
            if (findTypeInExpression(value.left, file, offset, analysis)) |target| return target;
            return findTypeInExpression(value.right, file, offset, analysis);
        },
        .logical => |value| {
            if (findTypeInExpression(value.left, file, offset, analysis)) |target| return target;
            return findTypeInExpression(value.right, file, offset, analysis);
        },
        .comparison => |value| for (value.operands) |operand| if (findTypeInExpression(operand, file, offset, analysis)) |target| return target,
        .call => |value| {
            if (findTypeInExpression(value.callee, file, offset, analysis)) |target| return target;
            for (value.arguments) |argument| if (findTypeInExpression(argument, file, offset, analysis)) |target| return target;
        },
        .range => |value| {
            if (findTypeInExpression(value.start, file, offset, analysis)) |target| return target;
            return findTypeInExpression(value.end, file, offset, analysis);
        },
        .interpolation => |parts| for (parts) |part| if (part == .expression) if (findTypeInExpression(part.expression, file, offset, analysis)) |target| return target,
        .list_literal, .tuple_literal => |items| for (items) |item| if (findTypeInExpression(item, file, offset, analysis)) |target| return target,
        .dictionary_literal => |entries| for (entries) |entry| {
            if (findTypeInExpression(entry.key, file, offset, analysis)) |target| return target;
            if (findTypeInExpression(entry.value, file, offset, analysis)) |target| return target;
        },
        .index => |value| {
            if (findTypeInExpression(value.base, file, offset, analysis)) |target| return target;
            return findTypeInExpression(value.index, file, offset, analysis);
        },
        .slice => |value| {
            if (findTypeInExpression(value.base, file, offset, analysis)) |target| return target;
            if (value.start) |start| if (findTypeInExpression(start, file, offset, analysis)) |target| return target;
            if (value.end) |end| return findTypeInExpression(end, file, offset, analysis);
        },
        .member => |value| return findTypeInExpression(value.base, file, offset, analysis),
        .lambda => |lambda| {
            for (lambda.parameters) |parameter| if (parameter.annotation) |annotation| if (checkTypeExpr(annotation, file, offset, analysis)) |target| return target;
            return switch (lambda.body) {
                .expression => |body| findTypeInExpression(body, file, offset, analysis),
                .block => |body| findTypeInStatements(body.statements, file, offset, analysis),
            };
        },
        .case_expression => |case| {
            if (case.subject) |subject| if (findTypeInExpression(subject, file, offset, analysis)) |target| return target;
            for (case.arms) |arm| {
                for (arm.alternatives) |alternative| if (findTypeInExpression(alternative, file, offset, analysis)) |target| return target;
                switch (arm.body) {
                    .block => |body| if (findTypeInStatements(body.statements, file, offset, analysis)) |target| return target,
                    .value => |body| if (findTypeInExpression(body, file, offset, analysis)) |target| return target,
                }
            }
            if (case.otherwise) |otherwise| switch (otherwise) {
                .block => |body| return findTypeInStatements(body.statements, file, offset, analysis),
                .value => |body| return findTypeInExpression(body, file, offset, analysis),
            };
        },
        .type_test => |value| {
            if (findTypeInExpression(value.value, file, offset, analysis)) |target| return target;
            return checkTypeExpr(value.target, file, offset, analysis);
        },
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .enum_value, .string_literal => {},
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
        .expression => |expression| return findDeclNameInExpression(expression, file, offset),
        .declaration => |d| {
            if (offset >= d.name_span.start and offset <= d.name_span.end) return .{ .file = file, .span = d.name_span };
            if (d.initializer) |initializer| return findDeclNameInExpression(initializer, file, offset);
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

fn findDeclNameInExpression(expression: *const Ast.Expression, file: u32, offset: u32) ?Resolver.Target {
    if (offset < expression.span.start or offset > expression.span.end) return null;
    switch (expression.data) {
        .unary => |value| return findDeclNameInExpression(value.operand, file, offset),
        .binary => |value| {
            if (findDeclNameInExpression(value.left, file, offset)) |target| return target;
            return findDeclNameInExpression(value.right, file, offset);
        },
        .logical => |value| {
            if (findDeclNameInExpression(value.left, file, offset)) |target| return target;
            return findDeclNameInExpression(value.right, file, offset);
        },
        .comparison => |value| for (value.operands) |operand| if (findDeclNameInExpression(operand, file, offset)) |target| return target,
        .call => |value| {
            if (findDeclNameInExpression(value.callee, file, offset)) |target| return target;
            for (value.arguments) |argument| if (findDeclNameInExpression(argument, file, offset)) |target| return target;
        },
        .range => |value| {
            if (findDeclNameInExpression(value.start, file, offset)) |target| return target;
            return findDeclNameInExpression(value.end, file, offset);
        },
        .interpolation => |parts| for (parts) |part| if (part == .expression) if (findDeclNameInExpression(part.expression, file, offset)) |target| return target,
        .list_literal, .tuple_literal => |items| for (items) |item| if (findDeclNameInExpression(item, file, offset)) |target| return target,
        .dictionary_literal => |entries| for (entries) |entry| {
            if (findDeclNameInExpression(entry.key, file, offset)) |target| return target;
            if (findDeclNameInExpression(entry.value, file, offset)) |target| return target;
        },
        .index => |value| {
            if (findDeclNameInExpression(value.base, file, offset)) |target| return target;
            return findDeclNameInExpression(value.index, file, offset);
        },
        .slice => |value| {
            if (findDeclNameInExpression(value.base, file, offset)) |target| return target;
            if (value.start) |start| if (findDeclNameInExpression(start, file, offset)) |target| return target;
            if (value.end) |end| return findDeclNameInExpression(end, file, offset);
        },
        .member => |value| return findDeclNameInExpression(value.base, file, offset),
        .lambda => |lambda| {
            for (lambda.parameters) |parameter| {
                if (offset >= parameter.name_span.start and offset <= parameter.name_span.end) return .{ .file = file, .span = parameter.name_span };
                if (parameter.pattern) |pattern| for (pattern.names) |name| {
                    if (offset >= name.span.start and offset <= name.span.end) return .{ .file = file, .span = name.span };
                };
            }
            return switch (lambda.body) {
                .expression => |body| findDeclNameInExpression(body, file, offset),
                .block => |body| findDeclNameInStatements(body.statements, file, offset),
            };
        },
        .case_expression => |case| {
            if (case.subject) |subject| if (findDeclNameInExpression(subject, file, offset)) |target| return target;
            for (case.arms) |arm| {
                for (arm.alternatives) |alternative| if (findDeclNameInExpression(alternative, file, offset)) |target| return target;
                switch (arm.body) {
                    .block => |body| if (findDeclNameInStatements(body.statements, file, offset)) |target| return target,
                    .value => |body| if (findDeclNameInExpression(body, file, offset)) |target| return target,
                }
            }
            if (case.otherwise) |otherwise| switch (otherwise) {
                .block => |body| return findDeclNameInStatements(body.statements, file, offset),
                .value => |body| return findDeclNameInExpression(body, file, offset),
            };
        },
        .type_test => |value| return findDeclNameInExpression(value.value, file, offset),
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .enum_value, .string_literal => {},
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
// statement and expression tree, including lambda bodies. A prelude target is
// an embedded declaration with no editor-visible file, but its project uses
// still have ordinary locations and are therefore returned too.

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
    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    // `includeDeclaration` can add a project declaration. The embedded
    // prelude has no URI an editor can open, so its declaration itself cannot
    // become a Location; its references below still can.
    if (include_declaration and target.file < loaded.project.files.len) try sites.append(gpa, target);
    // `analysis.parsed` ends with the embedded prelude. It participates in
    // resolution, but it has no project URI, so references report only the
    // project's real source files.
    for (analysis.parsed[0..loaded.project.files.len], 0..) |parsed, file_index| {
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
            if (analysis.checked.operator_calls.get(expr)) |key| {
                if (analysis.resolved.facts.declarations.get(key)) |found| {
                    if (targetEql(found, target)) try out.append(gpa, .{ .file = file, .span = b.operator_span });
                }
            }
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

// Rename.
//
// A rename is find references' own result set — the declaration and every
// site that reads, writes, or names it — with each site's span replaced by
// the new name, grouped into one `TextEdit` array per file.

fn onPrepareRename(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, id: std.json.Value, out: *std.Io.Writer) !void {
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
    // Prelude declarations have no file on disk to rename, so `onRename`
    // below declines them even though find references can report their uses.
    if (target.file >= loaded.project.files.len) {
        try respond(gpa, out, id, null);
        return;
    }
    if (isAnnotatedOperatorAt(&analysis, loaded.index, offset)) {
        try respond(gpa, out, id, null);
        return;
    }

    // The same set `onRename` would edit, reused rather than re-derived, so
    // the range this offers is always exactly what a rename from here would
    // actually touch: the declaration itself and every site find references
    // collects. Whichever one contains the cursor is the range to answer
    // with, and none of them will if the cursor turned out to be on
    // something else in the same expression (a call's arguments, say).
    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    try sites.append(gpa, target);
    for (analysis.parsed, 0..) |parsed, file_index| {
        try collectReferencesInStatements(gpa, &analysis, target, @intCast(file_index), parsed.program.statements, &sites);
    }

    for (sites.items) |site| {
        if (site.file == loaded.index and offset >= site.span.start and offset <= site.span.end) {
            try respond(gpa, out, id, lspRange(source, site.span));
            return;
        }
    }
    try respond(gpa, out, id, null);
}

fn onRename(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, new_name: []const u8, id: std.json.Value, out: *std.Io.Writer) !void {
    if (!isValidIdentifier(new_name)) {
        try respondError(gpa, out, id, invalid_params_code, "not a valid Emerald name");
        return;
    }

    const document = server.documents.get(uri) orelse {
        try respondError(gpa, out, id, invalid_params_code, "document not open");
        return;
    };

    var loaded = try loadDocument(server, gpa, uri, document.text.items);
    defer loaded.deinit(gpa);

    var analysis = (try emerald.analyzeProject(gpa, &loaded.project)) orelse {
        try respondError(gpa, out, id, invalid_params_code, "the project does not check cleanly");
        return;
    };
    defer analysis.deinit(gpa);

    const source = &loaded.project.files[loaded.index].source;
    const offset = offsetFromPosition(source, position);
    const target = (try definitionAt(gpa, &analysis, loaded.index, offset)) orelse {
        try respondError(gpa, out, id, invalid_params_code, "nothing here can be renamed");
        return;
    };
    // Prelude declarations are embedded in the binary: no file on disk to
    // write a rename into. Find references can still report their uses, but
    // rename cannot edit the declaration or present a complete edit set.
    if (target.file >= loaded.project.files.len) {
        try respondError(gpa, out, id, invalid_params_code, "a built-in name cannot be renamed");
        return;
    }
    if (isAnnotatedOperatorAt(&analysis, loaded.index, offset)) {
        try respondError(gpa, out, id, invalid_params_code, "an operator symbol cannot be renamed; rename its method name instead");
        return;
    }

    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    try sites.append(gpa, target);
    for (analysis.parsed, 0..) |parsed, file_index| {
        try collectReferencesInStatements(gpa, &analysis, target, @intCast(file_index), parsed.program.statements, &sites);
    }

    var by_file: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(TextEdit)) = .empty;
    defer {
        for (by_file.values()) |*edits| edits.deinit(gpa);
        by_file.deinit(gpa);
    }
    for (sites.items) |site| {
        const gop = try by_file.getOrPut(gpa, site.file);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const site_source = &loaded.project.files[site.file].source;
        if (isOperatorTokenSpan(site_source, site.span)) continue;
        try gop.value_ptr.append(gpa, .{ .range = lspRange(site_source, site.span), .newText = new_name });
    }

    var changes: std.json.ArrayHashMap([]const TextEdit) = .{};
    defer {
        for (changes.map.keys()) |key| gpa.free(key);
        for (changes.map.values()) |edits| gpa.free(edits);
        changes.map.deinit(gpa);
    }
    var file_iterator = by_file.iterator();
    while (file_iterator.next()) |entry| {
        const file_index = entry.key_ptr.*;
        const file_source_path = loaded.project.files[file_index].source.path;
        const site_uri = if (file_index == loaded.index)
            try gpa.dupe(u8, uri)
        else
            try pathToUri(gpa, file_source_path);
        const edits = try entry.value_ptr.toOwnedSlice(gpa);
        try changes.map.put(gpa, site_uri, edits);
    }

    try respond(gpa, out, id, WorkspaceEdit{ .changes = changes });
}

const WorkspaceEdit = struct { changes: std.json.ArrayHashMap([]const TextEdit) };

/// JSON-RPC's own "invalid params" code, reused for every reason `onRename`
/// declines: an unrenameable name is as much an invalid request as a
/// malformed one, and LSP defines no rename-specific code.
const invalid_params_code: i32 = -32602;

/// Whether `name` could be lexed back as a single identifier token — the
/// same rule `Lexer.lexIdentifier` uses (Unicode's XID classes, with a
/// single trailing `?` or `!` allowed) — checked so a rename is rejected
/// before it writes a name the parser would immediately choke on.
fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first, const first_len = unicode.decode(name, 0);
    if (!unicode.isIdentifierStart(first)) return false;
    var index: usize = first_len;
    while (index < name.len) {
        const c = name[index];
        if ((c == '?' or c == '!') and index == name.len - 1) {
            index += 1;
            continue;
        }
        const point, const length = unicode.decode(name, index);
        if (!unicode.isIdentifierContinue(point)) return false;
        index += length;
    }
    return true;
}

// Completion.
//
// The one piece that is not "more of the same" (see this file's header): a
// member access still being typed, `foo.` or `foo.par`, does not merely lack
// a type the checker never computed (hover's `.call` callee problem) — it
// fails to *parse* at all. `finishMember` (`Parser.zig`) reports a
// diagnostic and returns `error.ParseFailed`, which unwinds past the whole
// expression to the nearest statement boundary (`skipToNextStatement`), so
// nothing before the dot survives either. Building a real error-tolerant
// grammar to keep a partial node around would touch `Parser.zig`'s recovery
// for every caller — `check`, `run`, `format`, and every conformance and
// diagnostic golden file along with them — to serve one editor feature.
//
// Instead, a completion request patches a throwaway copy of the buffer:
// replace whatever partial name follows the dot with `placeholder()`, a
// fixed, always-valid synthetic call. A bare `placeholder` (no call) will
// not do: written where a statement is expected, section 5.2's "a call may
// discard its result, but a pure expression whose result is unused is a
// mistake" (`finishExpressionStatement`) discards it exactly like the
// original broken dot did, and a trailing `.` also suppresses the newline
// after it (`Lexer.zig`'s continuation rule, for fluent chains spanning
// lines), so an unparenthesized placeholder can silently swallow whatever
// real statement follows on the next line into the same expression. A call
// closes with `)` — a token that ends an expression, so neither problem
// applies — and always type-checks `foo`'s own type regardless of whether
// `placeholder` turns out to name a real member.
//
// The statement is very often still unclosed around the dot (`print(foo.`
// mid-call is the ordinary case, not the exception), so
// `appendUnclosedBrackets` also counts `(`, `[`, and `{` from the top of the
// file to the dot and closes what's still open — a plain character count,
// blind to string and comment contents, same tradeoff as every other
// heuristic in this file that reads source text directly rather than
// through the lexer. Nothing past the completion point is used for
// anything, so a later imbalance in the *real* file cannot make this worse.
//
// A type-qualified base (`Vector2.` for its type-level members, 10.4) is
// different: `Resolver.zig` validates it eagerly, so the synthetic unknown
// member fails resolution before the checker can record a type for the base.
// Rather than making the shared resolver tolerate a name it should reject in
// every other caller, completion reads the base path before the dot and finds
// its declaration in the resolver facts already gathered by this throwaway
// analysis. The same facts list a namespace's direct declarations. A bare
// identifier has no broken syntax at all, so its visible module keys are
// enough to offer useful top-level completions.

const CompletionItem = struct { label: []const u8 };

/// A member expression could not spell this — it is not a valid identifier,
/// so it cannot collide with a real member name — and long enough that a
/// short, real prefix never accidentally matches it while scanning for it.
const completion_placeholder = "emeraldLanguageServerCompletionPlaceholder";

fn onCompletion(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, id: std.json.Value, out: *std.Io.Writer) !void {
    const empty: []const CompletionItem = &.{};
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, empty);
        return;
    };

    const text = document.text.items;
    var temp_source = try Source.init(gpa, uri, text);
    defer temp_source.deinit(gpa);
    const cursor_offset = offsetFromPosition(&temp_source, position);

    const dot_offset = dotBeforeCursor(text, cursor_offset) orelse return onBareCompletion(server, gpa, uri, position, id, out);

    // A bare `placeholder` (no call) can land as a statement on its own —
    // `foo.\n` with nothing else on the line — where section 5.2's "a call
    // may discard its result, but a pure expression whose result is unused
    // is a mistake" rejects it outright (`finishExpressionStatement`,
    // `Parser.zig`), discarding the whole statement before the checker ever
    // sees it. `placeholder()` is always a call, so it always survives that
    // rule regardless of where it lands, and it closes with `)` — a token
    // that can end an expression — so it stops a dot's own newline
    // suppression from swallowing whatever real code follows on the next
    // line (`Lexer.zig`'s continuation rule: a trailing `.` continues a
    // statement onto the next line; a trailing `)` does not).
    var patched: std.ArrayList(u8) = .empty;
    defer patched.deinit(gpa);
    try patched.appendSlice(gpa, text[0 .. dot_offset + 1]);
    try patched.appendSlice(gpa, completion_placeholder);
    try patched.appendSlice(gpa, "()");
    try appendUnclosedBrackets(gpa, &patched, text, dot_offset);
    try patched.appendSlice(gpa, text[cursor_offset..]);

    var loaded = try loadDocument(server, gpa, uri, patched.items);
    defer loaded.deinit(gpa);

    var analysis = try emerald.analyzeProject(gpa, &loaded.project);
    defer if (analysis) |*found| found.deinit(gpa);

    // The base expression's own span still ends exactly at the dot in the
    // patched text, whether or not it ended up wrapped as a call's callee
    // (`Checker.typeOfMethodCall` types the base directly; a namespace- or
    // type-qualified callee is resolved without `typeOf` at all, the same
    // gap `definitionAt` works around — so this looks the base up by
    // position rather than by walking to the synthetic call itself).
    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);

    if (analysis) |*found| {
        if (findExpressionEndingAt(found, loaded.index, dot_offset)) |base| {
            if (found.checked.expression_types.get(base)) |base_info| {
                if (base_info.type.kind == .struct_value and base_info.type.user != null) {
                    try collectInstanceMembers(gpa, found, base_info.type.user.?.name, &items);
                }
            }
        }
    }

    // A type and namespace have no value expression for the checker to type.
    // Resolve their source path directly through the facts instead.
    if (items.items.len == 0) if (pathBeforeDot(text, dot_offset)) |written| {
        // The value-member patch intentionally contains an unknown member,
        // which is a resolver error for `Vector2.placeholder()`. Build one
        // second, resolver-clean view that replaces the entire incomplete
        // path with an ordinary call. Its facts still include every project
        // declaration, including the type or namespace we need to inspect.
        var facts_text: std.ArrayList(u8) = .empty;
        defer facts_text.deinit(gpa);
        const path_start = dot_offset - @as(u32, @intCast(written.len));
        try facts_text.appendSlice(gpa, text[0..path_start]);
        try facts_text.appendSlice(gpa, "print()");
        try appendUnclosedBrackets(gpa, &facts_text, text, path_start);
        try facts_text.appendSlice(gpa, text[cursor_offset..]);
        var facts_loaded = try loadDocument(server, gpa, uri, facts_text.items);
        defer facts_loaded.deinit(gpa);
        var facts_analysis = (try emerald.analyzeProject(gpa, &facts_loaded.project)) orelse {
            try respond(gpa, out, id, empty);
            return;
        };
        defer facts_analysis.deinit(gpa);

        const key = try completionPathKey(gpa, &facts_analysis, facts_loaded.index, written);
        defer gpa.free(key);
        if (facts_analysis.resolved.facts.declarations.get(key)) |target| {
            if (findStructDeclarationAt(&facts_analysis, target)) |s| {
                try collectTypeMembers(gpa, s, &items);
            } else {
                try collectNamespaceMembers(gpa, &facts_analysis, key, &items);
            }
        } else {
            try collectNamespaceMembers(gpa, &facts_analysis, key, &items);
        }
        // `items` borrows names from this throwaway analysis, so serialize
        // while its arena still owns those names.
        try respond(gpa, out, id, items.items);
        return;
    };

    try respond(gpa, out, id, items.items);
}

/// Completes names visible at a bare identifier. Resolver facts provide the
/// file-wide part; the parsed statement tree supplies the enclosing lexical
/// scopes, innermost first, so a local shadows a module name naturally.
fn onBareCompletion(server: *Server, gpa: std.mem.Allocator, uri: []const u8, position: Position, id: std.json.Value, out: *std.Io.Writer) !void {
    const empty: []const CompletionItem = &.{};
    const document = server.documents.get(uri) orelse {
        try respond(gpa, out, id, empty);
        return;
    };
    var source = try Source.init(gpa, uri, document.text.items);
    defer source.deinit(gpa);
    const cursor = offsetFromPosition(&source, position);
    var patched: std.ArrayList(u8) = .empty;
    defer patched.deinit(gpa);
    const start = identifierStartBefore(document.text.items, cursor);
    try patched.appendSlice(gpa, document.text.items[0..start]);
    try patched.appendSlice(gpa, "print()");
    try patched.appendSlice(gpa, document.text.items[cursor..]);

    var loaded = try loadDocument(server, gpa, uri, patched.items);
    defer loaded.deinit(gpa);
    var analysis = (try emerald.analyzeProject(gpa, &loaded.project)) orelse {
        try respond(gpa, out, id, empty);
        return;
    };
    defer analysis.deinit(gpa);

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    // `print()` replaces the typed prefix in the throwaway source. Its final
    // byte is the equivalent cursor position for walking the parsed scopes.
    const patched_cursor = start + @as(u32, @intCast("print()".len));
    try collectLocalCandidatesInStatements(gpa, analysis.parsed[loaded.index].program.statements, patched_cursor, &seen, &items);
    if (loaded.index < analysis.resolved.facts.module_keys.len) {
        var keys = analysis.resolved.facts.module_keys[loaded.index].keyIterator();
        while (keys.next()) |name| {
            // Resolver keeps type-level members in this table under their
            // internal `Type::member` key; they belong after a dot, not in a
            // bare completion list.
            if (std.mem.indexOf(u8, name.*, Resolver.method_separator) == null) try addCompletionOnce(gpa, &seen, &items, name.*);
        }
    }
    if (loaded.index < analysis.resolved.facts.namespace_aliases.len) {
        var aliases = analysis.resolved.facts.namespace_aliases[loaded.index].keyIterator();
        while (aliases.next()) |name| try addCompletionOnce(gpa, &seen, &items, name.*);
    }
    for (Resolver.prelude) |name| try addCompletionOnce(gpa, &seen, &items, name);
    try collectNamespaceMembersSeen(gpa, &analysis, "", &seen, &items);
    try respond(gpa, out, id, items.items);
}

/// Adds lexical bindings at `cursor`, from the innermost enclosing block out.
/// A statement block owns a scope (6.1), so its nested block is visited before
/// declarations in its parent; `seen` therefore preserves ordinary shadowing.
fn collectLocalCandidatesInStatements(
    gpa: std.mem.Allocator,
    statements: []const Ast.Statement,
    cursor: u32,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(CompletionItem),
) std.mem.Allocator.Error!void {
    // Lambdas are expressions rather than statements, so find one before the
    // statement-level block walk below. The recursive expression walk only
    // follows a child whose span contains the cursor.
    for (statements) |statement| {
        if (spanContains(statement.span, cursor) and try collectLambdaCandidatesInStatement(gpa, statement, cursor, seen, out)) return;
    }
    // Find the one nested scope containing the cursor first.
    nested: for (statements) |statement| switch (statement.data) {
        .function_declaration => |f| if (spanContains(f.body.span, cursor)) {
            try collectFunctionLocalCandidates(gpa, f, cursor, false, seen, out);
            break :nested;
        },
        .struct_declaration => |s| {
            if (s.constructor) |constructor| if (spanContains(constructor.body.span, cursor)) {
                try collectConstructorLocalCandidates(gpa, constructor, cursor, seen, out);
                break :nested;
            };
            for (s.methods) |method| if (spanContains(method.body.span, cursor)) {
                try collectFunctionLocalCandidates(gpa, method, cursor, true, seen, out);
                break :nested;
            };
            for (s.properties) |property| {
                if (spanContains(property.getter.body.span, cursor)) {
                    try collectFunctionLocalCandidates(gpa, property.getter, cursor, true, seen, out);
                    break :nested;
                }
                if (property.setter) |setter| if (spanContains(setter.body.span, cursor)) {
                    try collectFunctionLocalCandidates(gpa, setter, cursor, true, seen, out);
                    break :nested;
                };
            }
            for (s.type_functions) |type_function| if (spanContains(type_function.declaration.body.span, cursor)) {
                try collectFunctionLocalCandidates(gpa, type_function.declaration, cursor, false, seen, out);
                break :nested;
            };
        },
        .conditional => |conditional| {
            if (spanContains(conditional.then_block.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, conditional.then_block.statements, cursor, seen, out);
                break :nested;
            }
            if (conditional.otherwise) |otherwise| switch (otherwise) {
                .block => |block| if (spanContains(block.span, cursor)) {
                    try collectLocalCandidatesInStatements(gpa, block.statements, cursor, seen, out);
                    break :nested;
                },
                .chained => |chained| if (spanContains(chained.span, cursor)) {
                    try collectLocalCandidatesInStatements(gpa, &.{chained.*}, cursor, seen, out);
                    break :nested;
                },
            };
        },
        .while_loop => |loop| if (spanContains(loop.body.span, cursor)) {
            try collectLocalCandidatesInStatements(gpa, loop.body.statements, cursor, seen, out);
            break :nested;
        },
        .for_loop => |loop| if (spanContains(loop.body.span, cursor)) {
            try collectLocalCandidatesInStatements(gpa, loop.body.statements, cursor, seen, out);
            if (loop.pattern) |pattern| for (pattern.names) |name| try addCompletionOnce(gpa, seen, out, name.text) else if (loop.name.len != 0) try addCompletionOnce(gpa, seen, out, loop.name);
            break :nested;
        },
        .try_statement => |protected| {
            if (spanContains(protected.body.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, protected.body.statements, cursor, seen, out);
                break :nested;
            }
            for (protected.catches) |caught| if (spanContains(caught.body.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, caught.body.statements, cursor, seen, out);
                try addCompletionOnce(gpa, seen, out, caught.name);
                break :nested;
            };
            if (protected.finally_block) |finally_block| if (spanContains(finally_block.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, finally_block.statements, cursor, seen, out);
                break :nested;
            };
        },
        .case_statement => |case| {
            for (case.arms) |arm| if (arm.body == .block and spanContains(arm.body.block.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, arm.body.block.statements, cursor, seen, out);
                break :nested;
            };
            if (case.otherwise) |otherwise| if (otherwise == .block and spanContains(otherwise.block.span, cursor)) {
                try collectLocalCandidatesInStatements(gpa, otherwise.block.statements, cursor, seen, out);
                break :nested;
            };
        },
        else => {},
    };

    // This block's earlier declarations are visible at the cursor. A later
    // declaration is intentionally absent, matching the resolver's order.
    for (statements) |statement| {
        if (statement.span.start >= cursor) break;
        switch (statement.data) {
            .declaration => |declaration| try addCompletionOnce(gpa, seen, out, declaration.name),
            .destructuring => |destructuring| for (destructuring.pattern.names) |name| try addCompletionOnce(gpa, seen, out, name.text),
            .function_declaration => |function| try addCompletionOnce(gpa, seen, out, function.name),
            else => {},
        }
    }
}

fn collectFunctionLocalCandidates(
    gpa: std.mem.Allocator,
    function: Ast.FunctionDeclaration,
    cursor: u32,
    has_self: bool,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(CompletionItem),
) !void {
    try collectLocalCandidatesInStatements(gpa, function.body.statements, cursor, seen, out);
    for (function.parameters) |parameter| try addCompletionOnce(gpa, seen, out, parameter.name);
    if (has_self) try addCompletionOnce(gpa, seen, out, "self");
}

fn collectConstructorLocalCandidates(
    gpa: std.mem.Allocator,
    constructor: Ast.StructDeclaration.Constructor,
    cursor: u32,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(CompletionItem),
) !void {
    try collectLocalCandidatesInStatements(gpa, constructor.body.statements, cursor, seen, out);
    for (constructor.parameters) |parameter| try addCompletionOnce(gpa, seen, out, parameter.name);
    try addCompletionOnce(gpa, seen, out, "self");
}

fn collectLambdaCandidatesInStatement(gpa: std.mem.Allocator, statement: Ast.Statement, cursor: u32, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(CompletionItem)) std.mem.Allocator.Error!bool {
    return switch (statement.data) {
        .expression => |expression| collectLambdaCandidatesInExpression(gpa, expression, cursor, seen, out),
        .declaration => |declaration| if (declaration.initializer) |initializer| collectLambdaCandidatesInExpression(gpa, initializer, cursor, seen, out) else false,
        .assignment => |assignment| collectLambdaCandidatesInExpression(gpa, assignment.value, cursor, seen, out),
        .conditional => |conditional| collectLambdaCandidatesInExpression(gpa, conditional.condition, cursor, seen, out),
        .while_loop => |loop| collectLambdaCandidatesInExpression(gpa, loop.condition, cursor, seen, out),
        .for_loop => |loop| collectLambdaCandidatesInExpression(gpa, loop.iterable, cursor, seen, out),
        .return_statement => |returned| if (returned.value) |value| collectLambdaCandidatesInExpression(gpa, value, cursor, seen, out) else false,
        .raise_statement => |raised| if (raised.value) |value| collectLambdaCandidatesInExpression(gpa, value, cursor, seen, out) else false,
        .assert_statement => |assertion| blk: {
            if (try collectLambdaCandidatesInExpression(gpa, assertion.condition, cursor, seen, out)) break :blk true;
            break :blk if (assertion.message) |message| collectLambdaCandidatesInExpression(gpa, message, cursor, seen, out) else false;
        },
        .destructuring => |destructuring| collectLambdaCandidatesInExpression(gpa, destructuring.initializer, cursor, seen, out),
        else => false,
    };
}

fn collectLambdaCandidatesInExpression(gpa: std.mem.Allocator, expression: *const Ast.Expression, cursor: u32, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(CompletionItem)) std.mem.Allocator.Error!bool {
    if (!spanContains(expression.span, cursor)) return false;
    switch (expression.data) {
        .lambda => |lambda| {
            switch (lambda.body) {
                .expression => |body| _ = try collectLambdaCandidatesInExpression(gpa, body, cursor, seen, out),
                .block => |body| try collectLocalCandidatesInStatements(gpa, body.statements, cursor, seen, out),
            }
            for (lambda.parameters) |parameter| {
                if (parameter.pattern) |pattern| {
                    for (pattern.names) |name| try addCompletionOnce(gpa, seen, out, name.text);
                } else if (!std.mem.eql(u8, parameter.name, "_")) {
                    try addCompletionOnce(gpa, seen, out, parameter.name);
                }
            }
            return true;
        },
        .unary => |unary| return collectLambdaCandidatesInExpression(gpa, unary.operand, cursor, seen, out),
        .binary => |binary| {
            if (try collectLambdaCandidatesInExpression(gpa, binary.left, cursor, seen, out)) return true;
            return collectLambdaCandidatesInExpression(gpa, binary.right, cursor, seen, out);
        },
        .logical => |logical| {
            if (try collectLambdaCandidatesInExpression(gpa, logical.left, cursor, seen, out)) return true;
            return collectLambdaCandidatesInExpression(gpa, logical.right, cursor, seen, out);
        },
        .comparison => |comparison| for (comparison.operands) |operand| if (try collectLambdaCandidatesInExpression(gpa, operand, cursor, seen, out)) return true,
        .call => |call| {
            if (try collectLambdaCandidatesInExpression(gpa, call.callee, cursor, seen, out)) return true;
            for (call.arguments) |argument| if (try collectLambdaCandidatesInExpression(gpa, argument, cursor, seen, out)) return true;
        },
        .member => |member| return collectLambdaCandidatesInExpression(gpa, member.base, cursor, seen, out),
        .index => |index| {
            if (try collectLambdaCandidatesInExpression(gpa, index.base, cursor, seen, out)) return true;
            return collectLambdaCandidatesInExpression(gpa, index.index, cursor, seen, out);
        },
        .slice => |slice| {
            if (try collectLambdaCandidatesInExpression(gpa, slice.base, cursor, seen, out)) return true;
            if (slice.start) |start| if (try collectLambdaCandidatesInExpression(gpa, start, cursor, seen, out)) return true;
            if (slice.end) |end| return collectLambdaCandidatesInExpression(gpa, end, cursor, seen, out);
        },
        .range => |range| {
            if (try collectLambdaCandidatesInExpression(gpa, range.start, cursor, seen, out)) return true;
            return collectLambdaCandidatesInExpression(gpa, range.end, cursor, seen, out);
        },
        .list_literal, .tuple_literal => |items| for (items) |item| if (try collectLambdaCandidatesInExpression(gpa, item, cursor, seen, out)) return true,
        .dictionary_literal => |entries| for (entries) |entry| {
            if (try collectLambdaCandidatesInExpression(gpa, entry.key, cursor, seen, out)) return true;
            if (try collectLambdaCandidatesInExpression(gpa, entry.value, cursor, seen, out)) return true;
        },
        .interpolation => |parts| for (parts) |part| switch (part) {
            .text => {},
            .expression => |part_expression| if (try collectLambdaCandidatesInExpression(gpa, part_expression, cursor, seen, out)) return true,
        },
        .type_test => |test_expression| return collectLambdaCandidatesInExpression(gpa, test_expression.value, cursor, seen, out),
        else => {},
    }
    return false;
}

fn spanContains(span: Source.Span, offset: u32) bool {
    return offset >= span.start and offset <= span.end;
}

/// The offset of the `.` immediately before whatever identifier prefix (if
/// any) sits right before `cursor`, or null when `cursor` is not a member
/// access in progress at all.
fn dotBeforeCursor(text: []const u8, cursor: u32) ?u32 {
    var index = cursor;
    while (index > 0) {
        const c = text[index - 1];
        const is_identifier_byte = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!is_identifier_byte) break;
        index -= 1;
    }
    if (index == 0 or text[index - 1] != '.') return null;
    return index - 1;
}

/// The identifier path ending immediately before a member dot. This is only
/// an LSP recovery aid; the parser remains the authority for ordinary source.
fn pathBeforeDot(text: []const u8, dot: u32) ?[]const u8 {
    var start: usize = dot;
    while (start > 0) {
        const c = text[start - 1];
        const path_byte = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!path_byte) break;
        start -= 1;
    }
    return if (start == dot) null else text[start..dot];
}

fn identifierStartBefore(text: []const u8, cursor: u32) u32 {
    var start = cursor;
    while (start > 0) {
        const c = text[start - 1];
        const identifier_byte = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!identifier_byte) break;
        start -= 1;
    }
    return start;
}

fn completionPathKey(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, file: u32, written: []const u8) ![]u8 {
    if (analysis.resolved.facts.keyFor(file, written)) |key| return gpa.dupe(u8, key);
    const dot = std.mem.indexOfScalar(u8, written, '.') orelse {
        if (analysis.resolved.facts.namespaceAliasFor(file, written)) |alias| return gpa.dupe(u8, alias);
        return gpa.dupe(u8, written);
    };
    if (analysis.resolved.facts.namespaceAliasFor(file, written[0..dot])) |alias| {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ alias, written[dot..] });
    }
    return gpa.dupe(u8, written);
}

/// Appends whatever closes `(`, `[`, and `{` left open between the start of
/// `text` and `end` — a best-effort, string-only count, blind to string and
/// comment contents, like every other heuristic here that reads source text
/// directly. Silently caps at a depth no real program approaches, rather
/// than growing without bound on adversarial input.
fn appendUnclosedBrackets(gpa: std.mem.Allocator, patched: *std.ArrayList(u8), text: []const u8, end: u32) !void {
    var stack: [128]u8 = undefined;
    var depth: usize = 0;
    for (text[0..end]) |c| {
        switch (c) {
            '(', '[', '{' => {
                if (depth < stack.len) {
                    stack[depth] = switch (c) {
                        '(' => ')',
                        '[' => ']',
                        else => '}',
                    };
                }
                depth += 1;
            },
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    var i: usize = @min(depth, stack.len);
    while (i > 0) {
        i -= 1;
        try patched.append(gpa, stack[i]);
    }
}

/// The expression in `file` whose own span ends exactly at `offset` — the
/// only ambiguity a plain span comparison could have (some other, unrelated
/// expression coincidentally ending at the same byte in some other file) is
/// exactly what `file` rules out.
fn findExpressionEndingAt(analysis: *const emerald.Analysis, file: u32, offset: u32) ?*const Ast.Expression {
    var iterator = analysis.checked.expression_types.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.*.file != file) continue;
        if (entry.key_ptr.*.span.end == offset) return entry.key_ptr.*;
    }
    return null;
}

fn findStructDeclarationAt(analysis: *const emerald.Analysis, target: Resolver.Target) ?Ast.StructDeclaration {
    if (target.file >= analysis.parsed.len) return null;
    for (analysis.parsed[target.file].program.statements) |statement| {
        if (statement.data != .struct_declaration) continue;
        const s = statement.data.struct_declaration;
        if (s.name_span.start == target.span.start and s.name_span.end == target.span.end) return s;
    }
    return null;
}

fn addCompletionOnce(gpa: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(CompletionItem), name: []const u8) !void {
    const result = try seen.getOrPut(gpa, name);
    if (result.found_existing) return;
    try out.append(gpa, .{ .label = name });
}

/// A struct or class's own instance fields, properties, and methods — not
/// its type-level functions or fields (10.4), which belong to the type
/// itself rather than to a value of it, and not its constructor, which is
/// never written after a dot.
fn addInstanceMembers(s: Ast.StructDeclaration, gpa: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(CompletionItem)) !void {
    for (s.fields) |field| try addCompletionOnce(gpa, seen, out, field.name);
    for (s.properties) |property| try addCompletionOnce(gpa, seen, out, property.name);
    for (s.methods) |method| try addCompletionOnce(gpa, seen, out, method.name);
}

/// A value's own completions: `type_key`'s instance members, then its base
/// classes' (10.7), most-derived first so an override hides what it
/// overrides, then its adopted traits' (11.2).
fn collectInstanceMembers(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, type_key: []const u8, out: *std.ArrayList(CompletionItem)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    var current_key: ?[]const u8 = type_key;
    while (current_key) |key| {
        if (analysis.resolved.facts.declarations.get(key)) |target| {
            if (findStructDeclarationAt(analysis, target)) |s| try addInstanceMembers(s, gpa, &seen, out);
        }
        current_key = analysis.resolved.facts.bases.get(key);
    }

    if (analysis.resolved.facts.adopted.get(type_key)) |traits| {
        for (traits) |trait_key| {
            if (analysis.resolved.facts.declarations.get(trait_key)) |target| {
                if (findStructDeclarationAt(analysis, target)) |s| try addInstanceMembers(s, gpa, &seen, out);
            }
        }
    }
}

/// Section 10.4's members reached through a type rather than an instance.
/// They are not inherited, unlike the instance members above.
fn collectTypeMembers(gpa: std.mem.Allocator, s: Ast.StructDeclaration, out: *std.ArrayList(CompletionItem)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (s.type_functions) |function| try addCompletionOnce(gpa, &seen, out, function.member);
    for (s.type_fields) |field| try addCompletionOnce(gpa, &seen, out, field.name);
}

/// Direct children of `namespace`, plus direct child namespaces inferred from
/// declarations below it. Resolver keys use `::` for type members, which are
/// deliberately not namespace completions.
fn collectNamespaceMembers(gpa: std.mem.Allocator, analysis: *const emerald.Analysis, namespace: []const u8, out: *std.ArrayList(CompletionItem)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    try collectNamespaceMembersSeen(gpa, analysis, namespace, &seen, out);
}

fn collectNamespaceMembersSeen(
    gpa: std.mem.Allocator,
    analysis: *const emerald.Analysis,
    namespace: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(CompletionItem),
) !void {
    var declarations = analysis.resolved.facts.declarations.keyIterator();
    while (declarations.next()) |entry| {
        const key = entry.*;
        if (std.mem.indexOfScalar(u8, key, Resolver.private_separator[0]) != null) continue;
        if (namespace.len == 0 and std.mem.startsWith(u8, key, Resolver.prelude_namespace ++ ".")) continue;
        const rest = if (namespace.len == 0) key else blk: {
            if (!std.mem.startsWith(u8, key, namespace) or key.len <= namespace.len or key[namespace.len] != '.') continue;
            break :blk key[namespace.len + 1 ..];
        };
        if (rest.len == 0) continue;
        const type_member = std.mem.indexOf(u8, rest, Resolver.method_separator);
        const nested = std.mem.indexOfScalar(u8, rest, '.');
        const end = if (type_member) |member| if (nested) |dot| @min(member, dot) else member else nested orelse rest.len;
        if (type_member != null and (nested == null or type_member.? < nested.?)) continue;
        try addCompletionOnce(gpa, seen, out, rest[0..end]);
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

test "definitionAt jumps from an annotated arithmetic operator to its method" {
    const gpa = testing.allocator;
    const text =
        "struct Money {\n" ++
        "    const cents: Int\n" ++
        "\n" ++
        "    @operator(\"*\")\n" ++
        "    func times(quantity: Int): Money {\n" ++
        "        return Money(self.cents * quantity)\n" ++
        "    }\n" ++
        "}\n" ++
        "\n" ++
        "const price = Money(125)\n" ++
        "print(price * 3)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const operator_offset: u32 = @intCast(std.mem.indexOf(u8, text, "price * 3").? + "price ".len);
    const target = (try definitionAt(gpa, &analysis, 0, operator_offset)).?;
    const declaration_offset: u32 = @intCast(std.mem.indexOf(u8, text, "func times").? + "func ".len);
    try testing.expectEqual(@as(u32, 0), target.file);
    try testing.expectEqual(declaration_offset, target.span.start);
    try testing.expect(isAnnotatedOperatorAt(&analysis, 0, operator_offset));
    try testing.expect(!isAnnotatedOperatorAt(&analysis, 0, declaration_offset));
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

test "definitionAt reaches declarations, writes, and annotations inside a lambda block" {
    const gpa = testing.allocator;
    const text =
        "struct Token {}\n" ++
        "const action: func(Token): Nothing = { token: Token =>\n" ++
        "    var local = token\n" ++
        "    local = token\n" ++
        "    print(local)\n" ++
        "}\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const struct_offset: u32 = @intCast(std.mem.indexOf(u8, text, "struct Token").? + "struct ".len);
    const local_declaration: u32 = @intCast(std.mem.indexOf(u8, text, "local = token").?);

    // The parameter's explicit type is inside an expression, not a statement
    // header, and should still lead to the declared type.
    const parameter_type: u32 = @intCast(std.mem.indexOf(u8, text, "token: Token =>").? + "token: ".len);
    try testing.expectEqual(struct_offset, (try definitionAt(gpa, &analysis, 0, parameter_type)).?.span.start);

    // The declaration itself and a write both live in the lambda's block.
    try testing.expectEqual(local_declaration, (try definitionAt(gpa, &analysis, 0, local_declaration)).?.span.start);
    const local_write: u32 = @intCast(std.mem.indexOf(u8, text, "local = token\n    local").? + "local = token\n    ".len);
    try testing.expectEqual(local_declaration, (try definitionAt(gpa, &analysis, 0, local_write)).?.span.start);
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

test "collectReferencesInStatements finds named and operator uses of an annotated method" {
    const gpa = testing.allocator;
    const text =
        "struct Money {\n" ++
        "    const cents: Int\n" ++
        "\n" ++
        "    @operator(\"*\")\n" ++
        "    func times(quantity: Int): Money {\n" ++
        "        return Money(self.cents * quantity)\n" ++
        "    }\n" ++
        "}\n" ++
        "\n" ++
        "const price = Money(125)\n" ++
        "print(price.times(3))\n" ++
        "print(price * 3)\n";
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);

    const declaration_offset: u32 = @intCast(std.mem.indexOf(u8, text, "func times").? + "func ".len);
    const target = (try definitionAt(gpa, &analysis, 0, declaration_offset)).?;
    var sites: std.ArrayList(Resolver.Target) = .empty;
    defer sites.deinit(gpa);
    try collectReferencesInStatements(gpa, &analysis, target, 0, analysis.parsed[0].program.statements, &sites);

    try testing.expectEqual(@as(usize, 2), sites.items.len);
    const named_offset: u32 = @intCast(std.mem.indexOf(u8, text, "times(3)").?);
    const operator_offset: u32 = @intCast(std.mem.indexOf(u8, text, "price * 3").? + "price ".len);
    try testing.expectEqual(named_offset, sites.items[0].span.start);
    try testing.expectEqual(operator_offset, sites.items[1].span.start);
    try testing.expectEqual(@as(u32, 1), sites.items[1].span.len());
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

test "references returns project uses of an embedded prelude declaration" {
    const gpa = testing.allocator;
    var server: Server = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io() };
    defer server.deinit();
    const uri = "untitled:prelude-references.em";
    try server.store(uri, "const problem: RuntimeError = RuntimeError(\"hello\")\nprint(problem)\n");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // `RuntimeError` is an embedded prelude declaration. Its declaration has no
    // disk URI, but this written type use does.
    try onReferences(&server, gpa, uri, .{ .line = 0, .character = 15 }, true, .{ .integer = 1 }, &out.writer);

    var reader: std.Io.Reader = .fixed(out.written());
    var response = (try readMessage(gpa, &reader)).?;
    defer response.deinit();
    const locations = response.value.object.get("result").?.array.items;
    // The written type and the constructor call are both real project uses.
    try testing.expectEqual(@as(usize, 2), locations.len);
    try testing.expectEqualStrings(uri, locations[0].object.get("uri").?.string);
    const start = locations[0].object.get("range").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try testing.expectEqual(@as(i64, 15), start.get("character").?.integer);
}

test "isValidIdentifier accepts an ordinary name, a predicate name, and an accented one" {
    try testing.expect(isValidIdentifier("total"));
    try testing.expect(isValidIdentifier("_private"));
    try testing.expect(isValidIdentifier("starts_with?"));
    try testing.expect(isValidIdentifier("reverse!"));
    try testing.expect(isValidIdentifier("café"));
}

test "isValidIdentifier rejects an empty name, a leading digit, whitespace, and a mid-word ? or !" {
    try testing.expect(!isValidIdentifier(""));
    try testing.expect(!isValidIdentifier("1total"));
    try testing.expect(!isValidIdentifier("total count"));
    try testing.expect(!isValidIdentifier("total-count"));
    try testing.expect(!isValidIdentifier("is?even"));
    try testing.expect(!isValidIdentifier("do!thing"));
}

test "dotBeforeCursor finds the dot before an in-progress name, before nothing, and not at all" {
    const text = "foo.bar";
    try testing.expectEqual(@as(?u32, 3), dotBeforeCursor(text, 7));
    try testing.expectEqual(@as(?u32, 3), dotBeforeCursor(text, 4));
    try testing.expectEqual(@as(?u32, null), dotBeforeCursor(text, 3));
    try testing.expectEqual(@as(?u32, null), dotBeforeCursor("", 0));
}

test "appendUnclosedBrackets closes what a call left open, in matching order, and nothing when balanced" {
    const gpa = testing.allocator;
    var patched: std.ArrayList(u8) = .empty;
    defer patched.deinit(gpa);

    try appendUnclosedBrackets(gpa, &patched, "print(foo", 9);
    try testing.expectEqualStrings(")", patched.items);

    patched.clearRetainingCapacity();
    try appendUnclosedBrackets(gpa, &patched, "a([{foo", 7);
    try testing.expectEqualStrings("}])", patched.items);

    patched.clearRetainingCapacity();
    try appendUnclosedBrackets(gpa, &patched, "print(1, 2)", 11);
    try testing.expectEqualStrings("", patched.items);
}

test "collectInstanceMembers finds a class's own members and its base class's" {
    const gpa = testing.allocator;
    const text =
        \\class Animal {
        \\    var name: String
        \\    func speak() {}
        \\}
        \\class Dog extends Animal {
        \\    var breed: String
        \\    constructor(name: String, breed: String) {
        \\        super(name)
        \\        self.breed = breed
        \\    }
        \\}
        \\print(Dog("Rex", "Lab"))
    ;
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    try collectInstanceMembers(gpa, &analysis, "Dog", &items);

    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (items.items) |item| try labels.put(gpa, item.label, {});
    try testing.expect(labels.contains("breed"));
    try testing.expect(labels.contains("name"));
    try testing.expect(labels.contains("speak"));
    try testing.expectEqual(@as(usize, 3), items.items.len);
}

test "collectInstanceMembers finds a class's own members and its adopted trait's default" {
    const gpa = testing.allocator;
    const text =
        \\trait Greeter {
        \\    func greet(): String {
        \\        return "hi"
        \\    }
        \\}
        \\class Item with Greeter {
        \\    var id: Int
        \\}
        \\print(Item(1))
    ;
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    try collectInstanceMembers(gpa, &analysis, "Item", &items);

    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (items.items) |item| try labels.put(gpa, item.label, {});
    try testing.expect(labels.contains("id"));
    try testing.expect(labels.contains("greet"));
    try testing.expectEqual(@as(usize, 2), items.items.len);
}

test "completion collects a type's own type-level members, not its instance members" {
    const gpa = testing.allocator;
    const text =
        \\struct Vector {
        \\    var x: Int
        \\    func Vector.origin(): Vector {
        \\        return Vector(0)
        \\    }
        \\    const Vector.unit = Vector(1)
        \\}
        \\print(Vector.origin())
    ;
    var source = try Source.init(gpa, "t.em", text);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    const target = analysis.resolved.facts.declarations.get("Vector").?;
    const declaration = findStructDeclarationAt(&analysis, target).?;
    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    try collectTypeMembers(gpa, declaration, &items);

    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (items.items) |item| try labels.put(gpa, item.label, {});
    try testing.expect(labels.contains("origin"));
    try testing.expect(labels.contains("unit"));
    try testing.expect(!labels.contains("x"));
}

test "completion collects direct namespace members and child namespaces" {
    const gpa = testing.allocator;
    var main = try Source.init(gpa, "main.em", "using Art = Shapes\nprint(Art.area())\n");
    defer main.deinit(gpa);
    var shapes = try Source.init(gpa, "shapes/math.em",
        \\func area(): Int {
        \\    return 1
        \\}
    );
    defer shapes.deinit(gpa);
    var nested = try Source.init(gpa, "shapes/drawing/line.em", "func draw() {}\n");
    defer nested.deinit(gpa);
    var files = [_]emerald.Project.File{
        .{ .source = main, .namespace = "", .entry = true },
        .{ .source = shapes, .namespace = "Shapes", .entry = false },
        .{ .source = nested, .namespace = "Shapes.Drawing", .entry = false },
    };
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    try collectNamespaceMembers(gpa, &analysis, "Shapes", &items);
    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (items.items) |item| try labels.put(gpa, item.label, {});
    try testing.expect(labels.contains("area"));
    try testing.expect(labels.contains("Drawing"));

    const alias_key = try completionPathKey(gpa, &analysis, 0, "Art");
    defer gpa.free(alias_key);
    try testing.expectEqualStrings("Shapes", alias_key);
}

test "completion handler answers type members and a bare visible name" {
    const gpa = testing.allocator;
    var server: Server = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io() };
    defer server.deinit();
    const uri = "untitled:completion.em";

    const type_text =
        \\struct Vector {
        \\    func Vector.origin(): Vector {
        \\        return Vector()
        \\    }
        \\    const Vector.unit = Vector()
        \\}
        \\Vector.
    ;
    try server.store(uri, type_text);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try onCompletion(&server, gpa, uri, .{ .line = 6, .character = 7 }, .{ .integer = 1 }, &out.writer);
    var reader: std.Io.Reader = .fixed(out.written());
    var response = (try readMessage(gpa, &reader)).?;
    defer response.deinit();
    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (response.value.object.get("result").?.array.items) |item| {
        const label = item.object.get("label").?;
        try testing.expect(label == .string);
        try labels.put(gpa, label.string, {});
    }
    try testing.expect(labels.contains("origin"));
    try testing.expect(labels.contains("unit"));

    out.clearRetainingCapacity();
    try server.store(uri, "pri");
    try onCompletion(&server, gpa, uri, .{ .line = 0, .character = 3 }, .{ .integer = 2 }, &out.writer);
    reader = .fixed(out.written());
    var bare_response = (try readMessage(gpa, &reader)).?;
    defer bare_response.deinit();
    labels.clearRetainingCapacity();
    for (bare_response.value.object.get("result").?.array.items) |item| {
        const label = item.object.get("label").?;
        try testing.expect(label == .string);
        try labels.put(gpa, label.string, {});
    }
    try testing.expect(labels.contains("print"));

    out.clearRetainingCapacity();
    try server.store(uri,
        \\func total(first: Int): Int {
        \\    const second = 2
        \\    if true {
        \\        inn
        \\    }
        \\    const after = 3
        \\    return first + second
        \\}
    );
    try onCompletion(&server, gpa, uri, .{ .line = 3, .character = 11 }, .{ .integer = 3 }, &out.writer);
    reader = .fixed(out.written());
    var local_response = (try readMessage(gpa, &reader)).?;
    defer local_response.deinit();
    labels.clearRetainingCapacity();
    for (local_response.value.object.get("result").?.array.items) |item| {
        const label = item.object.get("label").?;
        try testing.expect(label == .string);
        try labels.put(gpa, label.string, {});
    }
    try testing.expect(labels.contains("first"));
    try testing.expect(labels.contains("second"));
    try testing.expect(!labels.contains("after"));

    out.clearRetainingCapacity();
    try server.store(uri,
        \\[1].each { value =>
        \\    val
        \\}
    );
    try onCompletion(&server, gpa, uri, .{ .line = 1, .character = 7 }, .{ .integer = 4 }, &out.writer);
    reader = .fixed(out.written());
    var lambda_response = (try readMessage(gpa, &reader)).?;
    defer lambda_response.deinit();
    labels.clearRetainingCapacity();
    for (lambda_response.value.object.get("result").?.array.items) |item| {
        const label = item.object.get("label").?;
        try testing.expect(label == .string);
        try labels.put(gpa, label.string, {});
    }
    try testing.expect(labels.contains("value"));

    out.clearRetainingCapacity();
    try server.store(uri,
        \\struct Box {
        \\    func inspect() {
        \\        sel
        \\    }
        \\}
    );
    try onCompletion(&server, gpa, uri, .{ .line = 2, .character = 11 }, .{ .integer = 5 }, &out.writer);
    reader = .fixed(out.written());
    var method_response = (try readMessage(gpa, &reader)).?;
    defer method_response.deinit();
    labels.clearRetainingCapacity();
    for (method_response.value.object.get("result").?.array.items) |item| {
        const label = item.object.get("label").?;
        try testing.expect(label == .string);
        try labels.put(gpa, label.string, {});
    }
    try testing.expect(labels.contains("self"));
}

test "completion end to end: a broken member access mid-call patches into something the checker can type" {
    const gpa = testing.allocator;
    const text = "struct Point {\n    var x: Int\n    var y: Int\n}\nconst p = Point(1, 2)\nprint(p.\n";
    const dot_position: u32 = @intCast(std.mem.indexOf(u8, text, "p.\n").? + 1);
    const cursor: u32 = dot_position + 1;
    try testing.expectEqual(@as(?u32, dot_position), dotBeforeCursor(text, cursor));

    var patched: std.ArrayList(u8) = .empty;
    defer patched.deinit(gpa);
    try patched.appendSlice(gpa, text[0 .. dot_position + 1]);
    try patched.appendSlice(gpa, completion_placeholder);
    try patched.appendSlice(gpa, "()");
    try appendUnclosedBrackets(gpa, &patched, text, dot_position);
    try patched.appendSlice(gpa, text[cursor..]);

    var source = try Source.init(gpa, "t.em", patched.items);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };

    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    // Not `analysis.ok()`: the checker rightly reports that `Point` has no
    // method by the placeholder's name — same as hovering a typo reports one
    // — but it still resolves and records `p`'s own type regardless, which
    // is the only thing completion actually needs from this pass.
    try testing.expect(!analysis.ok());

    const base = findExpressionEndingAt(&analysis, 0, dot_position).?;
    const base_info = analysis.checked.expression_types.get(base).?;
    try testing.expectEqualStrings("Point", base_info.type.user.?.name);

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(gpa);
    try collectInstanceMembers(gpa, &analysis, base_info.type.user.?.name, &items);

    var labels: std.StringHashMapUnmanaged(void) = .empty;
    defer labels.deinit(gpa);
    for (items.items) |item| try labels.put(gpa, item.label, {});
    try testing.expect(labels.contains("x"));
    try testing.expect(labels.contains("y"));
}
