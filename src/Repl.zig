//! `emerald repl` (section 18.4): keeps declarations and values across
//! entries, prints a bare expression's value, and clears with `:reset`.
//!
//! The compiler's pipeline (`Resolver.resolve`, `Checker.check`,
//! `Interpreter.run`) is built as a single-shot, whole-project pass —
//! `emerald.zig`'s own words: "Resolution, checking and execution each see
//! the whole project at once." Nothing about module scope, struct type
//! identity, or heap objects survives past one `Interpreter.run` call today,
//! and 14.1 lets only one file (`entry = true`) hold executable top-level
//! statements — every other file is restricted by `Resolver.checkModuleFile`
//! to declarations only. Threading interpreter/heap state and checker facts
//! across separate entries would mean real surgery to `Interpreter.run`'s
//! signature and reconciling `Type.User`'s pointer identity across repeated
//! `Checker.check` calls, which compares structs by pointer, not name.
//!
//! Instead, a REPL session is modeled as **one single, always-growing entry
//! file**, re-lexed, re-parsed, re-resolved, re-checked, and re-run from
//! scratch by the completely unmodified `emerald.run` on every accepted
//! entry. This sidesteps the one-entry-file restriction entirely (there is
//! only ever one file), and gives every existing binding rule — a name may
//! not be redeclared, a `const` may not be reassigned, a `var` may — for
//! free, with no REPL-specific logic anywhere in the compiler. What replay
//! has to solve on its own, both below: not re-printing old output, and not
//! re-consuming fresh `input()` on replay. Every language feature that exists
//! today is observable only through `print`/`input` (no clock, filesystem,
//! network, or randomness), so this is not an approximation — it is exactly
//! correct, at the cost of redoing more work per entry than a truly
//! incremental interpreter would, a cost invisible at typing speed.

const std = @import("std");
const emerald = @import("emerald");
const Source = emerald.Source;
const Diagnostic = emerald.Diagnostic;
const Lexer = emerald.Lexer;
const Parser = emerald.Parser;

/// Everything the session remembers between entries. Only ever mutated by
/// `commit`/`reset`, so an entry that fails to check or that raises simply
/// never touches it — section 18.4's "an invalid entry does not partially
/// mutate the session," extended to a raising one too (see `tryEntry`).
const Session = struct {
    text: std.ArrayList(u8) = .empty,
    /// Bytes of `text`'s captured output already shown to the user.
    output_len: usize = 0,
    /// Every byte a successful entry's `input()` has ever consumed, replayed
    /// at the front of every later attempt so a program that already asked
    /// its questions does not ask them again.
    recorded_input: std.ArrayList(u8) = .empty,

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.recorded_input.deinit(gpa);
        self.* = undefined;
    }

    fn reset(self: *Session, gpa: std.mem.Allocator) void {
        self.text.clearRetainingCapacity();
        self.output_len = 0;
        self.recorded_input.clearRetainingCapacity();
        _ = gpa;
    }
};

/// A `std.Io.Reader` that serves `recorded` first, then falls through to
/// `live`, appending whatever it reads from `live` onto `newly_read` so the
/// *next* attempt's replay can include it. Every previously recorded byte
/// came from a complete `streamDelimiterEnding` line (`input()`'s own read
/// idiom, `Interpreter.evaluateInput`), so the two never need to interleave
/// within one read: once `recorded` is exhausted, everything after is live.
const ReplayReader = struct {
    interface: std.Io.Reader,
    recorded: []const u8,
    recorded_pos: usize = 0,
    live: *std.Io.Reader,
    newly_read: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn init(
        recorded: []const u8,
        live: *std.Io.Reader,
        newly_read: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        buffer: []u8,
    ) ReplayReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .recorded = recorded,
            .live = live,
            .newly_read = newly_read,
            .gpa = gpa,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ReplayReader = @fieldParentPtr("interface", r);
        if (self.recorded_pos < self.recorded.len) {
            const chunk = limit.sliceConst(self.recorded[self.recorded_pos..]);
            try w.writeAll(chunk);
            self.recorded_pos += chunk.len;
            return chunk.len;
        }
        // `live` is the one shared reader for the whole session — the
        // REPL's own prompt-reading uses it too, on later turns as much as
        // this one. Anything pulled from it here and not immediately handed
        // to `w` (and recorded) would strand unrecovered bytes in this
        // call's own throwaway buffer, permanently lost to `live` once this
        // one attempt's `ReplayReader` goes out of scope — so exactly one
        // byte is requested at a time, regardless of `limit`, never more
        // than what this call hands off in full. `live`'s own buffering
        // (`Interpreter.evaluateInput`'s `peekGreedy`/`toss`, and the
        // streaming file reader beneath it) already absorbs the real cost of
        // this, one syscall at a time, not one byte at a time.
        var scratch: std.Io.Writer.Allocating = .init(self.gpa);
        defer scratch.deinit();
        const n = try self.live.stream(&scratch.writer, limit.min(.limited(1)));
        try w.writeAll(scratch.written());
        self.newly_read.appendSlice(self.gpa, scratch.written()) catch return error.ReadFailed;
        return n;
    }
};

/// Runs the REPL until end of input. `in`/`out` are the one shared,
/// long-lived stdin/stdout streams for the whole process — both the REPL's
/// own prompt-reading and every entry's `input()` calls read from the same
/// underlying stream, so there is exactly one of each for the session.
pub fn run(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var session: Session = .{};
    defer session.deinit(gpa);

    try out.writeAll("Emerald REPL. `:reset` clears the session; Ctrl-D exits.\n");

    entries: while (true) {
        try out.writeAll("> ");
        try out.flush();

        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(gpa);

        while (true) {
            const line = (try readLine(gpa, in)) orelse break :entries;
            defer gpa.free(line);

            if (pending.items.len == 0 and std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), ":reset")) {
                session.reset(gpa);
                try out.writeAll("Session cleared.\n");
                continue :entries;
            }

            try pending.appendSlice(gpa, line);
            try pending.append(gpa, '\n');

            if (std.mem.trim(u8, pending.items, " \t\r\n").len == 0) {
                // Nothing but blank lines so far: start over rather than
                // asking the lexer/parser to classify empty input.
                pending.clearRetainingCapacity();
                try out.writeAll("> ");
                try out.flush();
                continue;
            }

            switch (try classifyEntry(gpa, pending.items)) {
                .incomplete => {
                    try out.writeAll(". ");
                    try out.flush();
                    continue;
                },
                .invalid => |rendered| {
                    defer gpa.free(rendered);
                    try out.writeAll(rendered);
                    try out.flush();
                    continue :entries;
                },
                .complete => |wrap| {
                    if (wrap) {
                        const trimmed = std.mem.trim(u8, pending.items, " \t\r\n");
                        var wrapped: std.ArrayList(u8) = .empty;
                        defer wrapped.deinit(gpa);
                        try wrapped.appendSlice(gpa, "print(");
                        try wrapped.appendSlice(gpa, trimmed);
                        try wrapped.appendSlice(gpa, ")\n");
                        try tryEntry(gpa, &session, wrapped.items, in, out);
                    } else {
                        try tryEntry(gpa, &session, pending.items, in, out);
                    }
                    continue :entries;
                },
            }
        }
    }

    try out.writeAll("\n");
    try out.flush();
}

/// Reads one line, without its terminator, the same way `Interpreter.input`
/// does. Returns `null` only at a clean end of input with nothing left to
/// give (matching `evaluateInput`'s `at_end and length == 0`).
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
    const bytes = std.mem.trimEnd(u8, line.written(), "\r");
    return try gpa.dupe(u8, bytes);
}

const Classification = union(enum) {
    /// Still missing a closing delimiter or quote; read another line.
    incomplete,
    /// A genuine syntax error, already rendered against the entry's own text.
    invalid: []const u8,
    /// Ready to try. `true` means this is section 18.4's "a bare expression":
    /// exactly one expression statement that is not already a call, whose
    /// value should be displayed by wrapping it in `print(...)` before it is
    /// tried against the session.
    complete: bool,
};

/// Classifies `text` on its own, before it is ever combined with the
/// session: completeness (an open delimiter, comment, or triple-quoted
/// string) is a property of the entry's own token/tree shape, independent of
/// anything declared earlier.
fn classifyEntry(gpa: std.mem.Allocator, text: []const u8) !Classification {
    var source = try Source.init(gpa, "<repl>", text);
    defer source.deinit(gpa);

    var tokenized = try Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    if (tokenized.diagnostics.len != 0) {
        if (lexerLooksIncomplete(tokenized.diagnostics)) return .incomplete;
        return .{ .invalid = try renderAgainst(gpa, &source, tokenized.diagnostics) };
    }

    var parsed = try Parser.parse(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        // `Parser.finishExpressionStatement` rejects a bare expression that
        // is not a call as a parse error, not a checker one — 5.2's "only a
        // call" rule is enforced immediately, so a bare expression never
        // becomes a `Statement.Data.expression` node to inspect at all. This
        // is precisely section 18.4's "a bare expression prints its value":
        // the one diagnostic, with nothing else parsed alongside it, means
        // the whole entry was exactly one such expression.
        if (parsed.diagnostics.len == 1 and parsed.program.statements.len == 0 and
            std.mem.eql(u8, parsed.diagnostics[0].message, "this result is never used"))
        {
            return .{ .complete = true };
        }
        if (parserLooksIncomplete(parsed.diagnostics, @intCast(text.len))) return .incomplete;
        return .{ .invalid = try renderAgainst(gpa, &source, parsed.diagnostics) };
    }

    return .{ .complete = false };
}

/// The lexer only ever reports these two messages when its scan ran off the
/// true end of input, never for a genuinely malformed construct — see
/// `Lexer.skipBlockComment` and `Lexer.unterminated`. A `"this string is
/// never closed"` diagnostic is only the "still typing" case when its span
/// is the 3-byte `"""` delimiter (`Lexer.unterminated`'s `delimiter.len == 3`
/// branch); the same message with a 1-byte span means an ordinary or raw
/// string hit a bare newline, which is a permanent error since neither may
/// span a line by grammar.
fn lexerLooksIncomplete(diagnostics: []const Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        const is_block_comment = std.mem.eql(u8, diagnostic.message, "this block comment is never closed");
        const is_open_string = std.mem.eql(u8, diagnostic.message, "this string is never closed") and
            diagnostic.span.len() == 3;
        if (!is_block_comment and !is_open_string) return false;
    }
    return true;
}

/// Two distinct patterns in `Parser.zig` both mean "ran out of input," and
/// look different because they serve different readers.
///
/// A closing delimiter expected somewhere other than a block's `}` — a
/// call's `)`, an index's `]`, a dictionary's `]`, and so on — is reported as
/// `"expected ... found {s}"`, where `{s}` is `Token.Kind.describe()`; for
/// the lexer's one, always-present `.eof` token (a zero-width span at the
/// true end of the text, `Lexer.zig`'s `next`/`emit`) that reads "found the
/// end of the file," and the diagnostic's span is that same zero-width EOF
/// position — structurally checkable without matching text.
///
/// A `{ ... }` body — a function/if/while/for's block, a `case`, or a
/// lambda — instead reports "this block/`case`/lambda is never closed" at
/// its *opening* brace, so the reader sees which block is unclosed rather
/// than only "found EOF"; each of the three is only ever reached after its
/// own parse loop breaks specifically on `.eof` (`Parser.zig`'s `parseBlock`,
/// `parseCaseArms`, and the lambda-block parser all check `.right_brace` or
/// `.eof` to end their loop), so the message alone is a reliable signal here.
fn parserLooksIncomplete(diagnostics: []const Diagnostic, text_len: u32) bool {
    for (diagnostics) |diagnostic| {
        const at_eof = diagnostic.span.start == text_len and diagnostic.span.end == text_len;
        const unclosed_block = std.mem.eql(u8, diagnostic.message, "this block is never closed") or
            std.mem.eql(u8, diagnostic.message, "this `case` is never closed") or
            std.mem.eql(u8, diagnostic.message, "this lambda is never closed");
        if (!at_eof and !unclosed_block) return false;
    }
    return true;
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

/// Tries `entry_text` (already classified as complete, and print-wrapped if
/// it was a bare expression) appended to the whole session, and commits it
/// only on success.
fn tryEntry(
    gpa: std.mem.Allocator,
    session: *Session,
    entry_text: []const u8,
    live_in: *std.Io.Reader,
    out: *std.Io.Writer,
) !void {
    var scratch_text: std.ArrayList(u8) = .empty;
    defer scratch_text.deinit(gpa);
    try scratch_text.appendSlice(gpa, session.text.items);
    try scratch_text.appendSlice(gpa, entry_text);

    var source = try Source.init(gpa, "<repl>", scratch_text.items);
    defer source.deinit(gpa);

    var captured: std.Io.Writer.Allocating = .init(gpa);
    defer captured.deinit();

    var newly_read: std.ArrayList(u8) = .empty;
    defer newly_read.deinit(gpa);
    var reader_buffer: [256]u8 = undefined;
    var replay = ReplayReader.init(session.recorded_input.items, live_in, &newly_read, gpa, &reader_buffer);

    var report = try emerald.run(gpa, &source, .{ .out = &captured.writer, .in = &replay.interface });
    defer report.deinit();

    const sources = [_]Source{source};

    if (report.diagnostics.len != 0) {
        for (report.diagnostics) |diagnostic| {
            diagnostic.render(&sources, out) catch |err| return mapWriterError(err);
        }
        try out.flush();
        return; // `session` is untouched.
    }

    const new_output = captured.written()[session.output_len..];
    out.writeAll(new_output) catch |err| return mapWriterError(err);

    if (report.failure) |failure| {
        failure.render(&sources, out) catch |err| return mapWriterError(err);
        try out.flush();
        return; // Discarded deliberately — see this file's header comment.
    }

    session.text.clearRetainingCapacity();
    try session.text.appendSlice(gpa, scratch_text.items);
    session.output_len = captured.written().len;
    try session.recorded_input.appendSlice(gpa, newly_read.items);
    try out.flush();
}

fn mapWriterError(err: std.Io.Writer.Error) error{WriteFailed} {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
    };
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

fn expectComplete(text: []const u8, wrap: bool) !void {
    const gpa = testing.allocator;
    switch (try classifyEntry(gpa, text)) {
        .complete => |got_wrap| try testing.expectEqual(wrap, got_wrap),
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

test "a bare non-call expression is complete and marked to be wrapped in print" {
    try expectComplete("1 + 2\n", true);
    try expectComplete("x.count\n", true);
}

test "a call statement is complete and left exactly as written" {
    try expectComplete("print(1)\n", false);
    try expectComplete("var x = 1\n", false);
}
