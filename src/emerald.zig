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
pub const Resolver = @import("Resolver.zig");
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

    var resolved = try Resolver.resolve(gpa, parsed.program);
    defer resolved.deinit();
    if (!resolved.ok()) {
        const copies = try dupeDiagnostics(arena, resolved.diagnostics);
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
    _ = Resolver;
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

// Section 4.3 and 6.1: bindings, assignment, and scope.

test "the first milestone program" {
    try expectOutput("var score = 2 + 3 * 4\nprint(score)\n", "14\n");
}

test "var rebinds and const does not" {
    try expectOutput("var n = 1\nn = 2\nprint(n)\n", "2\n");
    try expectFailure("const n = 1\nn = 2\n", "`n` cannot be reassigned");
}

test "compound assignment lowers through the matching operation" {
    try expectOutput("var n = 10\nn += 5\nprint(n)\n", "15\n");
    try expectOutput("var n = 10\nn -= 5\nprint(n)\n", "5\n");
    try expectOutput("var n = 10\nn *= 3\nprint(n)\n", "30\n");
    try expectOutput("var n = 7\nn //= 2\nprint(n)\n", "3\n");
    // `/=` follows `/`, which always produces a Float.
    try expectOutput("var n = 10\nn /= 4\nprint(n)\n", "2.5\n");
}

test "assignment is a statement and cannot be chained" {
    try expectFailure("var a = 1\nvar b = 2\na = b = 3\n", "assignments cannot be chained");
}

test "shadowing a visible local is rejected, including across a block" {
    try expectFailure("var n = 1\nvar n = 2\n", "`n` is already declared");
    try expectFailure("var n = 1\nif true {\n  var n = 2\n}\n", "`n` is already declared");
}

test "sibling scopes may reuse a name" {
    try expectOutput(
        "if true {\n  var n = 1\n  print(n)\n}\nif true {\n  var n = 2\n  print(n)\n}\n",
        "1\n2\n",
    );
}

test "a local does not leak out of its block" {
    try expectFailure("if true {\n  var inner = 1\n}\nprint(inner)\n", "`inner` is not defined");
}

test "a name must be declared before it is used" {
    try expectFailure("print(missing)\n", "`missing` is not defined");
    try expectFailure("missing = 1\n", "`missing` is not defined");
    // The initializer resolves before the name is introduced, so this reports
    // the right-hand side rather than quietly seeing itself.
    try expectFailure("var n = n\n", "`n` is not defined");
}

// Section 6.2: conditionals.

test "if, else if, and else select one branch" {
    const program =
        \\var n = 5
        \\if n > 10 {
        \\    print(1)
        \\}
        \\else if n > 3 {
        \\    print(2)
        \\}
        \\else {
        \\    print(3)
        \\}
        \\
    ;
    try expectOutput(program, "2\n");
}

test "a condition must be a Bool" {
    try expectFailure("if 1 {\n  print(1)\n}\n", "a condition must be a Bool, but this is Int");
    try expectFailure("if nothing {\n  print(1)\n}\n", "a condition must be a Bool, but this is Nothing");
}

// Section 5.2: comparison and the word operators.

test "comparisons produce a Bool" {
    try expectOutput("print(1 < 2)\n", "true\n");
    try expectOutput("print(1 > 2)\n", "false\n");
    try expectOutput("print(2 == 2)\n", "true\n");
    try expectOutput("print(2 != 2)\n", "false\n");
    try expectOutput("print(2 <= 2, 2 >= 3)\n", "true false\n");
}

test "a chained comparison reads as the conjunction of its links" {
    try expectOutput("print(0 <= 5 <= 100)\n", "true\n");
    try expectOutput("print(0 <= 500 <= 100)\n", "false\n");
    try expectOutput("print(1 < 2 < 3 < 4)\n", "true\n");
}

test "a chained comparison short-circuits before evaluating the next operand" {
    // Dividing by zero raises. Reaching it would fail the program, so a plain
    // `false` proves the chain stopped at the first false link.
    try expectOutput("print(2 < 1 < 1 // 0)\n", "false\n");
}

test "and and or short-circuit" {
    try expectOutput("print(false and 1 // 0 == 0)\n", "false\n");
    try expectOutput("print(true or 1 // 0 == 0)\n", "true\n");
    try expectOutput("print(true and false)\n", "false\n");
    try expectOutput("print(false or true)\n", "true\n");
}

test "not inverts a Bool and rejects anything else" {
    try expectOutput("print(not true)\n", "false\n");
    try expectOutput("print(not (1 > 2))\n", "true\n");
    try expectFailure("print(not 1)\n", "`not` needs a Bool, but this is Int");
}

test "a mixed comparison compares mathematical values" {
    // Widening the Int would round it to the Float and make these equal.
    try expectOutput("print(9007199254740993 == 9007199254740992.0)\n", "false\n");
    try expectOutput("print(9007199254740993 > 9007199254740992.0)\n", "true\n");
    try expectOutput("print(2 == 2.0)\n", "true\n");
    try expectOutput("print(2 < 2.5)\n", "true\n");
}

test "NaN follows IEEE comparison behavior" {
    const nan = "var nan = 1e308 * 10 - 1e308 * 10\n";
    try expectOutput(nan ++ "print(nan == nan)\n", "false\n");
    try expectOutput(nan ++ "print(nan != nan)\n", "true\n");
    try expectOutput(nan ++ "print(nan < 1.0)\n", "false\n");
    try expectOutput(nan ++ "print(nan >= 1.0)\n", "false\n");
}

test "values of different kinds cannot be compared or added" {
    try expectFailure("print(1 < true)\n", "Int and Bool cannot be compared");
    try expectFailure("print(1 + true)\n", "addition needs numbers, but this is Int and Bool");
}

// Section 4.2 and 15.2: `nothing`.

test "nothing is a value and print has no result" {
    try expectOutput("print(nothing)\n", "nothing\n");
    try expectOutput("var result = print(1)\nprint(result)\n", "1\nnothing\n");
}

test "a program may declare a name matching a prelude function" {
    // The prelude is not a local, so this is not the shadowing section 6.1 forbids.
    try expectOutput("var print_count = 0\nprint(print_count)\n", "0\n");
}
