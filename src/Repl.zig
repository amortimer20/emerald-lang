//! A persistent interactive session: accepted syntax is kept, analysis is
//! replaced atomically, and only the new entry executes. Failed entries keep
//! completed effects but lose their declarations. Input has one scheduler owner.

const std = @import("std");
const emerald = @import("emerald");
const Source = emerald.Source;
const Diagnostic = emerald.Diagnostic;
const Lexer = emerald.Lexer;
const Parser = emerald.Parser;
const Interpreter = emerald.Interpreter;

pub const Options = struct {
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    standard_input: bool = false,
};
const stack_size: usize = if (@sizeOf(usize) >= 8) 1024 * 1024 * 1024 else 32 * 1024 * 1024;
pub const Error = emerald.Error || error{ReadFailed};

/// The prompt and typed input share one reader, including across :reset.
/// Recursive interpretation stays on the same reserved stack for the session.
pub fn run(gpa: std.mem.Allocator, input: *std.Io.Reader, out: *std.Io.Writer, color: bool, environment: std.process.Environ, local_zone: emerald.TimeZone.Local, options: Options) Error!u8 {
    const Work = struct {
        gpa: std.mem.Allocator,
        input: *std.Io.Reader,
        out: *std.Io.Writer,
        color: bool,
        environment: std.process.Environ,
        local_zone: emerald.TimeZone.Local,
        options: Options,
        result: Error!u8 = undefined,
        fn execute(self: *@This()) void {
            self.result = loop(self.gpa, self.input, self.out, self.color, self.environment, self.local_zone, self.options);
        }
    };
    var work: Work = .{ .gpa = gpa, .input = input, .out = out, .color = color, .environment = environment, .local_zone = local_zone, .options = options };
    const thread = emerald.Scheduler.ReservedThread.spawn(stack_size, Work.execute, .{&work}) catch return error.StackUnavailable;
    thread.join();
    return work.result;
}

fn newRuntime(gpa: std.mem.Allocator, syntax: *emerald.SessionSyntax, input: *std.Io.Reader, out: *std.Io.Writer, color: bool, environment: std.process.Environ, local_zone: emerald.TimeZone.Local, options: Options, reader: *emerald.Scheduler.InputReader) Error!*Interpreter.Session {
    _ = syntax.append(gpa, "") catch return error.OutOfMemory;
    const analysis = try gpa.create(emerald.Analysis);
    errdefer gpa.destroy(analysis);
    analysis.* = (try emerald.analyzeSession(gpa, syntax)).?;
    errdefer analysis.deinit(gpa);
    // Borrow during construction, then transfer ownership only on success.
    const runtime = try Interpreter.Session.init(gpa, emerald.sessionAnalysis(analysis), out, input, options.io, &.{}, color, options.standard_input, environment, local_zone, Interpreter.StackLimit.here(stack_size));
    runtime.current = emerald.ownedSessionAnalysis(analysis);
    runtime.shareInput(reader);
    return runtime;
}

fn loop(gpa: std.mem.Allocator, input: *std.Io.Reader, out: *std.Io.Writer, color: bool, environment: std.process.Environ, local_zone: emerald.TimeZone.Local, options: Options) Error!u8 {
    const reader = if (options.standard_input)
        emerald.Scheduler.InputReader.standard() catch return error.OutOfMemory
    else
        emerald.Scheduler.InputReader.fixed(gpa, input) catch return error.OutOfMemory;
    defer reader.deinit();
    var syntax: emerald.SessionSyntax = .{};
    defer syntax.deinit(gpa);
    var runtime: ?*Interpreter.Session = try newRuntime(gpa, &syntax, input, out, color, environment, local_zone, options, reader);
    defer if (runtime) |session| session.deinit();
    try out.writeAll("Emerald REPL. Type `:help` for commands; Ctrl-D exits.\n");
    entries: while (true) {
        try out.writeAll("> ");
        try out.flush();
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(gpa);
        while (true) {
            const line = try runtime.?.readLine();
            defer gpa.free(line.bytes);
            if (line.at_end and line.bytes.len == 0) break :entries;
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (pending.items.len == 0) {
                if (std.mem.eql(u8, trimmed, ":quit")) break :entries;
                if (std.mem.eql(u8, trimmed, ":help")) {
                    try out.writeAll(
                        \\Commands:
                        \\  :help   show these commands
                        \\  :reset  clear the session
                        \\  :quit   leave the REPL
                        \\
                        \\Names cannot be redeclared; use :reset to start over.
                        \\An entry that fails to check changes nothing. An entry that raises loses
                        \\its declarations, but keeps completed assignments, output, and outside effects.
                        \\
                    );
                    continue :entries;
                }
                if (std.mem.eql(u8, trimmed, ":reset")) {
                    runtime.?.deinit();
                    runtime = null;
                    syntax.deinit(gpa);
                    syntax = .{};
                    runtime = try newRuntime(gpa, &syntax, input, out, color, environment, local_zone, options, reader);
                    try out.writeAll("Session cleared.\n");
                    continue :entries;
                }
            }
            try pending.appendSlice(gpa, std.mem.trimEnd(u8, line.bytes, "\r"));
            try pending.append(gpa, '\n');
            if (std.mem.trim(u8, pending.items, " \t\r\n").len == 0) continue :entries;
            switch (try classifyEntry(gpa, pending.items)) {
                .incomplete => {
                    try out.writeAll(". ");
                    try out.flush();
                    continue;
                },
                .invalid => |rendered| {
                    defer gpa.free(rendered);
                    syntax.retainInvalid(gpa, pending.items) catch return error.OutOfMemory;
                    try out.writeAll(rendered);
                    break;
                },
                .complete => {},
            }
            const candidate = syntax.append(gpa, pending.items) catch return error.OutOfMemory;
            const start = candidate.statement_start;
            var renderer: Renderer = .{ .gpa = gpa, .syntax = &syntax, .out = out };
            const analysis = try gpa.create(emerald.Analysis);
            const checked = emerald.analyzeSessionWithOptions(gpa, &syntax, .{ .context = &renderer, .unresolved = Renderer.unresolved }) catch |err| {
                gpa.destroy(analysis);
                return err;
            };
            if (checked == null) {
                gpa.destroy(analysis);
                syntax.dropLast();
                break;
            }
            analysis.* = checked.?;
            var transferred = false;
            defer if (!transferred) {
                analysis.deinit(gpa);
                gpa.destroy(analysis);
            };
            renderer.files = analysis.files;
            try renderer.report(analysis.resolved.diagnostics);
            try renderer.report(analysis.checked.diagnostics);
            if (!analysis.ok()) {
                syntax.dropLast();
                break;
            }
            transferred = true; // install takes ownership before it can fail
            try runtime.?.install(emerald.ownedSessionAnalysis(analysis), start);
            switch (try runtime.?.runInteractiveEntry(analysis.programs[0].statements[start..], &analysis.checked.expression_types)) {
                .complete => {},
                .failed => |failure| {
                    try renderer.report(&.{failure});
                    syntax.dropLast();
                },
                .exited => |status| {
                    try out.flush();
                    return status;
                },
            }
            break;
        }
    }
    try out.writeAll("\n");
    try out.flush();
    return 0;
}

/// Remap each span independently: a trace or related failure can come from a
/// different entry, including a failed entry whose code escaped. Prelude spans
/// retain their own source. No diagnostic wording outside the REPL is changed.
const Renderer = struct {
    gpa: std.mem.Allocator,
    syntax: *const emerald.SessionSyntax,
    out: *std.Io.Writer,
    files: []const emerald.Project.File = &.{},

    fn unresolved(context: ?*anyopaque, files: []const emerald.Project.File, diagnostics: []const Diagnostic) emerald.Error!void {
        const self: *Renderer = @ptrCast(@alignCast(context.?));
        self.files = files;
        try self.report(diagnostics);
    }

    fn entryIndex(self: *const Renderer, offset: u32) usize {
        var low: usize = 0;
        var high = self.syntax.entries.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.syntax.entries.items[middle].text_start <= offset) low = middle + 1 else high = middle;
        }
        return low -| 1;
    }

    fn remap(self: *const Renderer, arena: std.mem.Allocator, original: Diagnostic) !Diagnostic {
        var diagnostic = original;
        if (diagnostic.file == 0) {
            const index = self.entryIndex(diagnostic.span.start);
            const offset: u32 = @intCast(self.syntax.entries.items[index].text_start);
            diagnostic.file = @intCast(self.files.len + index);
            diagnostic.span = .{ .start = diagnostic.span.start - offset, .end = diagnostic.span.end - offset };
        }
        const trace = try arena.dupe(Diagnostic.Frame, diagnostic.trace);
        for (trace) |*frame| if (frame.file == 0) {
            const index = self.entryIndex(frame.call_span.start);
            const offset: u32 = @intCast(self.syntax.entries.items[index].text_start);
            frame.file = @intCast(self.files.len + index);
            frame.call_span = .{ .start = frame.call_span.start - offset, .end = frame.call_span.end - offset };
        };
        diagnostic.trace = trace;
        if (diagnostic.related) |related| {
            const copied = try arena.create(Diagnostic);
            copied.* = try self.remap(arena, related.*);
            diagnostic.related = copied;
        }
        if (self.topLevelDeclaration(original) and std.mem.endsWith(u8, diagnostic.message, "is already declared")) diagnostic.help = "Declare a different name, or type :reset to start over.";
        return diagnostic;
    }

    fn topLevelDeclaration(self: *const Renderer, diagnostic: Diagnostic) bool {
        if (diagnostic.file != 0) return false;
        const parsed = self.syntax.entries.items[self.syntax.entries.items.len - 1].parsed.program;
        for (parsed.using) |declaration| if (declaration.alias.len != 0 and declaration.alias_span.start == diagnostic.span.start) return true;
        for (parsed.statements) |statement| {
            const span = switch (statement.data) {
                .declaration => |declaration| declaration.name_span,
                .function_declaration => |declaration| declaration.name_span,
                .struct_declaration => |declaration| declaration.name_span,
                else => continue,
            };
            if (span.start == diagnostic.span.start) return true;
        }
        return false;
    }

    fn report(self: *const Renderer, diagnostics: []const Diagnostic) emerald.Error!void {
        if (diagnostics.len == 0) return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sources = try arena.alloc(Source, self.files.len + self.syntax.entries.items.len);
        for (self.files, 0..) |file, index| sources[index] = file.source;
        for (self.syntax.entries.items, self.files.len..) |entry, index| sources[index] = try Source.init(arena, "repl", entry.source.text[entry.text_start..]);
        const current = self.syntax.entries.items[self.syntax.entries.items.len - 1].text_start;
        for (diagnostics) |original| {
            // Whole-program checking can repeat an earlier warning; show it
            // only when its entry is submitted, not on every later analysis.
            if (original.severity == .warning and original.file == 0 and original.span.start < current) continue;
            const diagnostic = try self.remap(arena, original);
            try diagnostic.render(sources, self.out);
        }
    }
};

const Classification = union(enum) {
    /// Still missing a closing delimiter or quote; read another line.
    incomplete,
    /// A genuine syntax error, already rendered against the entry's own text.
    invalid: []const u8,
    /// Ready to execute; true marks a single expression, calls included.
    complete: bool,
};

/// Classifies `text` on its own, before it is ever combined with the
/// session: completeness (an open delimiter, comment, or triple-quoted
/// string) is a property of the entry's own token/tree shape, independent of
/// anything declared earlier.
fn classifyEntry(gpa: std.mem.Allocator, text: []const u8) !Classification {
    var source = try Source.init(gpa, "repl", text);
    defer source.deinit(gpa);

    var tokenized = try Lexer.tokenizeFrom(gpa, &source, 0);
    defer tokenized.deinit(gpa);
    if (tokenized.diagnostics.len != 0) {
        if (tokenized.incomplete_at_end) return .incomplete;
        return .{ .invalid = try renderAgainst(gpa, &source, tokenized.diagnostics) };
    }

    var parsed = try Parser.parseEntry(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    if (parsed.incomplete_at_end) return .incomplete;
    if (parsed.diagnostics.len != 0) {
        return .{ .invalid = try renderAgainst(gpa, &source, parsed.diagnostics) };
    }

    if (parsed.program.statements.len == 1 and parsed.program.statements[0].interactive_expression) {
        return .{ .complete = true };
    }
    return .{ .complete = false };
}

fn renderAgainst(gpa: std.mem.Allocator, source: *const Source, diagnostics: []const Diagnostic) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const sources = [_]Source{source.*};
    for (diagnostics) |diagnostic| {
        diagnostic.render(&sources, &out.writer) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

fn expectIncomplete(text: []const u8) !void {
    const gpa = testing.allocator;
    switch (try classifyEntry(gpa, text)) {
        .incomplete => {},
        .complete => return error.TestUnexpectedResult,
        .invalid => |rendered| {
            defer gpa.free(rendered);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectComplete(text: []const u8, expression: bool) !void {
    const gpa = testing.allocator;
    switch (try classifyEntry(gpa, text)) {
        .complete => |got_expression| try testing.expectEqual(expression, got_expression),
        .incomplete => return error.TestUnexpectedResult,
        .invalid => |rendered| {
            defer gpa.free(rendered);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectInvalid(text: []const u8) !void {
    const gpa = testing.allocator;
    switch (try classifyEntry(gpa, text)) {
        .invalid => |rendered| gpa.free(rendered),
        .incomplete => return error.TestUnexpectedResult,
        .complete => return error.TestUnexpectedResult,
    }
}

test "an open block, case, or lambda asks for another line" {
    try expectIncomplete("if true {\n");
    try expectIncomplete("func f() {\n    return 1\n");
    try expectIncomplete("case 1 {\n    when 1 {\n");
    try expectIncomplete("const f = { x =>\n");
}

test "an open call, list, or group asks for another line" {
    try expectIncomplete("print(\n    1,\n");
    try expectIncomplete("const xs = [\n    1,\n");
    try expectIncomplete("const y = (\n    1 + 2\n");
}

test "an open block comment or triple-quoted string asks for another line" {
    try expectIncomplete("#[\n  still going\n");
    try expectIncomplete("print(\"\"\"\n  still going\n");
}

test "a single-quoted or double-quoted string cannot span a line, so it is a real error" {
    try expectInvalid("print(\"oops\n");
    try expectInvalid("print('oops\n");
}

test "an ordinary syntax error is not mistaken for an incomplete entry" {
    try expectInvalid("var = 1\n");
}

test "a bare expression is complete and marked for echo" {
    try expectComplete("1 + 2\n", true);
    try expectComplete("x.count\n", true);
}

test "calls are expressions too; declarations are not" {
    try expectComplete("print(1)\n", true);
    try expectComplete("var x = 1\n", false);
}

test "a file append executes once and its effect survives session teardown" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.txt", .data = "" });
    const relative = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/log.txt", .{tmp.sub_path});
    defer gpa.free(relative);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, gpa);
    defer gpa.free(absolute);
    // JSON's ASCII escape spelling also safely quotes Windows paths for
    // Emerald. No host path is spliced into source without escaping.
    const literal = try std.json.Stringify.valueAlloc(gpa, absolute, .{});
    defer gpa.free(literal);
    const transcript = try std.fmt.allocPrint(gpa, "File.append({s}, \"x\")\nprint(1)\nprint(2)\n:quit\n", .{literal});
    defer gpa.free(transcript);
    for (0..50) |_| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.txt", .data = "" });
        var input: std.Io.Reader = .fixed(transcript);
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        try testing.expectEqual(@as(u8, 0), try run(gpa, &input, &output.writer, false, .empty, .utc, .{}));
        const contents = try tmp.dir.readFileAlloc(testing.io, "log.txt", gpa, .unlimited);
        defer gpa.free(contents);
        try testing.expectEqualStrings("x", contents);
        try testing.expectEqualStrings("Emerald REPL. Type `:help` for commands; Ctrl-D exits.\n> > 1\n> 2\n> \n", output.written());
    }
}

test "a program's exit status and preceding output survive the REPL" {
    var input: std.Io.Reader = .fixed("if true {\n    print(\"bye\")\n    exit(7)\n}\n");
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(@as(u8, 7), try run(testing.allocator, &input, &output.writer, false, .empty, .utc, .{}));
    try testing.expectEqualStrings("Emerald REPL. Type `:help` for commands; Ctrl-D exits.\n> . . . bye\n", output.written());
}
