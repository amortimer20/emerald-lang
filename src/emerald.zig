//! The Emerald frontend library.
//!
//! The pipeline described in section 19.2 is source manager, lexer, parser,
//! resolver, checker, interpreter. Name resolution and type checking do not
//! exist yet; the others are wired together by `check` and `run` below.

const std = @import("std");

pub const Source = @import("Source.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Ast = @import("Ast.zig");
pub const Parser = @import("Parser.zig");
pub const Value = @import("Value.zig");
pub const Interpreter = @import("Interpreter.zig");

/// Everything a stage reported, owned by one arena.
pub const Report = struct {
    arena_state: std.heap.ArenaAllocator,
    /// Problems found before execution. Non-empty means nothing ran.
    diagnostics: []const Diagnostic,
    /// The error that stopped execution, when execution started and failed.
    failure: ?Diagnostic = null,

    pub fn ok(self: Report) bool {
        return self.diagnostics.len == 0 and self.failure == null;
    }

    pub fn deinit(self: *Report) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

/// Analyses a source file without running it, as section 18.1 requires of
/// `emerald check`: the same analysis as `run`, with nothing executed.
pub fn check(gpa: std.mem.Allocator, source: *const Source) !Report {
    return analyze(gpa, source, null);
}

/// Checks a source file and then executes it, writing program output to `out`.
pub fn run(gpa: std.mem.Allocator, source: *const Source, out: *std.Io.Writer) !Report {
    return analyze(gpa, source, out);
}

/// Runs each stage in order, stopping at the first that reports anything.
///
/// Stopping is deliberate. Section 17.2 asks for one primary error rather than a
/// cascade, and a parser fed a broken token stream produces exactly that cascade.
fn analyze(gpa: std.mem.Allocator, source: *const Source, out: ?*std.Io.Writer) !Report {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    // Encoding. Lexing bytes that are not text would only invent confusion on
    // top of a problem the reader has to fix first.
    if (Source.findInvalidUtf8(source.text)) |span| {
        const only = try arena.alloc(Diagnostic, 1);
        only[0] = .{
            .message = "this is not valid UTF-8 text",
            .span = span,
            .help = "Emerald source files are always UTF-8. Re-save this file as UTF-8.",
        };
        return .{ .arena_state = arena_state, .diagnostics = only };
    }

    var tokenized = try Lexer.tokenize(gpa, source);
    defer tokenized.deinit(gpa);
    if (tokenized.diagnostics.len != 0) {
        // Every allocation has to finish before the arena is copied into the
        // result, because copying it snapshots the list of blocks it owns.
        const copies = try dupeDiagnostics(arena, tokenized.diagnostics);
        return .{ .arena_state = arena_state, .diagnostics = copies };
    }

    var parsed = try Parser.parse(gpa, source, tokenized.tokens);
    defer parsed.deinit();
    if (!parsed.ok()) {
        const copies = try dupeDiagnostics(arena, parsed.diagnostics);
        return .{ .arena_state = arena_state, .diagnostics = copies };
    }

    const writer = out orelse return .{ .arena_state = arena_state, .diagnostics = &.{} };

    var outcome = try Interpreter.run(gpa, source, parsed.program, writer);
    defer outcome.deinit();

    const failure = if (outcome.failure) |raised|
        try dupeDiagnostic(arena, raised)
    else
        null;

    return .{ .arena_state = arena_state, .diagnostics = &.{}, .failure = failure };
}

/// Diagnostics point at text owned by the stage that produced them, and every
/// stage is released as soon as the next one starts, so they are copied into the
/// report's own arena.
fn dupeDiagnostic(arena: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
    return .{
        .message = try arena.dupe(u8, diagnostic.message),
        .span = diagnostic.span,
        .help = try arena.dupe(u8, diagnostic.help),
    };
}

fn dupeDiagnostics(arena: std.mem.Allocator, diagnostics: []const Diagnostic) ![]const Diagnostic {
    const copies = try arena.alloc(Diagnostic, diagnostics.len);
    for (diagnostics, copies) |diagnostic, *copy| copy.* = try dupeDiagnostic(arena, diagnostic);
    return copies;
}

const testing = std.testing;

test {
    _ = Source;
    _ = Diagnostic;
    _ = Token;
    _ = Lexer;
    _ = Ast;
    _ = Parser;
    _ = Value;
    _ = Interpreter;
}

/// Runs a program and returns what it printed. The caller owns the result.
fn runToString(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var source = try Source.init(gpa, "test.em", text);
    defer source.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var report = try run(gpa, &source, &out.writer);
    defer report.deinit();

    if (!report.ok()) {
        const problem = if (report.failure) |failure| failure else report.diagnostics[0];
        std.debug.print("unexpected: {s}\n", .{problem.message});
        return error.UnexpectedDiagnostic;
    }

    return out.toOwnedSlice();
}

fn expectOutput(text: []const u8, expected: []const u8) !void {
    const actual = try runToString(testing.allocator, text);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectFailure(text: []const u8, expected_message: []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var report = try run(testing.allocator, &source, &out.writer);
    defer report.deinit();

    const problem = report.failure orelse
        if (report.diagnostics.len != 0) report.diagnostics[0] else return error.ExpectedAFailure;
    try testing.expectEqualStrings(expected_message, problem.message);
}

test "the first milestone expression" {
    try expectOutput("print(2 + 3 * 4)\n", "14\n");
}

test "precedence and grouping" {
    try expectOutput("print((2 + 3) * 4)\n", "20\n");
    try expectOutput("print(10 - 2 - 3)\n", "5\n"); // left associative
    try expectOutput("print(2 + 3 * 4 - 6 / 3)\n", "12.0\n"); // `/` makes it a Float
}

test "exponentiation binds tighter than unary minus and associates right to left" {
    try expectOutput("print(-2 ** 2)\n", "-4.0\n");
    try expectOutput("print(2 ** 3 ** 2)\n", "512.0\n");
    try expectOutput("print((-2) ** 2)\n", "4.0\n");
    try expectOutput("print(2 ** -1)\n", "0.5\n");
}

test "exponentiation always produces a Float" {
    try expectOutput("print(2 ** 10)\n", "1024.0\n");
}

test "ordinary division always produces a Float" {
    try expectOutput("print(6 / 3)\n", "2.0\n");
    try expectOutput("print(7 / 2)\n", "3.5\n");
}

test "floor division rounds toward negative infinity" {
    try expectOutput("print(7 // 2)\n", "3\n");
    try expectOutput("print(-7 // 2)\n", "-4\n");
    try expectOutput("print(7 // -2)\n", "-4\n");
    try expectOutput("print(7.0 // 2)\n", "3.0\n");
}

test "remainder pairs with floor division and takes the divisor's sign" {
    try expectOutput("print(7 % 3)\n", "1\n");
    try expectOutput("print(-7 % 3)\n", "2\n");
    try expectOutput("print(7 % -3)\n", "-2\n");
}

test "the floor division law holds for the signs that make it interesting" {
    // a == (a // b) * b + (a % b)
    try expectOutput("print(-7 // 3 * 3 + -7 % 3)\n", "-7\n");
    try expectOutput("print(7 // -3 * -3 + 7 % -3)\n", "7\n");
}

test "an Int and a Float widen to Float" {
    try expectOutput("print(1 + 2.5)\n", "3.5\n");
    try expectOutput("print(2 * 1.5)\n", "3.0\n");
}

test "print takes zero or more values separated by one space" {
    try expectOutput("print()\n", "\n");
    try expectOutput("print(1, 2, 3)\n", "1 2 3\n");
}

test "several statements run in order" {
    try expectOutput("print(1)\nprint(2)\n", "1\n2\n");
}

test "integer overflow is reported rather than wrapping" {
    try expectFailure("print(9223372036854775807 + 1)\n", "addition of 9223372036854775807 and 1 overflows Int");
    try expectFailure("print(-9223372036854775807 - 2)\n", "subtraction of -9223372036854775807 and 2 overflows Int");
    try expectFailure("print(4611686018427387904 * 4)\n", "multiplication of 4611686018427387904 and 4 overflows Int");
}

test "division by zero is an error for both numeric types" {
    try expectFailure("print(1 / 0)\n", "division by zero");
    try expectFailure("print(1.0 / 0.0)\n", "division by zero");
    try expectFailure("print(1 // 0)\n", "floor division by zero");
    try expectFailure("print(1 % 0)\n", "remainder by zero");
}

test "a result that is never used is rejected with the likely correction" {
    try expectFailure("2 + 3\n", "this result is never used");
}

test "an undefined name is reported by name" {
    try expectFailure("print(score)\n", "`score` is not defined");
}

test "a number outside the Int range is rejected at its literal" {
    try expectFailure("print(99999999999999999999)\n", "this number is outside the range of Int");
}

test "underscores in a literal carry no value" {
    try expectOutput("print(1_000_000)\n", "1000000\n");
}
