//! The Emerald frontend library.
//!
//! The pipeline described in section 19.2 is source manager, lexer, parser,
//! resolver, checker, interpreter. All of them exist now, wired together by
//! `check` and `run` below.
//!
//! Every stage after the lexer recurses over the tree, so the whole pipeline
//! runs on a thread with a large stack, sized for section 7.2's 1,000 active
//! calls at section 3.4's deepest guaranteed nesting in a Debug build, where
//! frames are largest. The parser bounds how tall any tree can grow before a
//! later stage walks it, and the interpreter guards the stack as it goes.

const std = @import("std");
const builtin = @import("builtin");

pub const Source = @import("Source.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Ast = @import("Ast.zig");
pub const Parser = @import("Parser.zig");
pub const Resolver = @import("Resolver.zig");
pub const Type = @import("Type.zig");
pub const Checker = @import("Checker.zig");
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

pub const Error = Interpreter.RunError || error{
    /// The large-stack thread could not be created, so the pipeline cannot
    /// keep section 7.2's guarantees and does not start.
    StackUnavailable,
};

/// Analyses a source file without running it, as section 18.1 requires of
/// `emerald check`: the same analysis as `run`, with nothing executed.
pub fn check(gpa: std.mem.Allocator, source: *const Source) Error!Report {
    return onLargeStack(gpa, source, null);
}

/// Checks a source file and then executes it, writing program output to `out`.
pub fn run(gpa: std.mem.Allocator, source: *const Source, out: *std.Io.Writer) Error!Report {
    return onLargeStack(gpa, source, out);
}

/// Reserved rather than committed: the host maps a thread's stack lazily, so
/// the unused part costs address space and nothing else.
///
/// In a Debug build, a function body nested 250 operations deep reached only
/// about 800 calls in 256 MiB, so this is twice that. Release builds reach the
/// full 1,000 in half the space.
const stack_size: usize = if (@sizeOf(usize) >= 8) 512 * 1024 * 1024 else 32 * 1024 * 1024;

comptime {
    if (builtin.single_threaded) @compileError(
        "Emerald runs its pipeline on a thread with a large stack, so it cannot be built single-threaded.",
    );
}

fn onLargeStack(gpa: std.mem.Allocator, source: *const Source, out: ?*std.Io.Writer) Error!Report {
    const Task = struct {
        gpa: std.mem.Allocator,
        source: *const Source,
        out: ?*std.Io.Writer,
        result: Error!Report = undefined,

        fn go(task: *@This(), available: usize) void {
            task.result = analyze(task.gpa, task.source, task.out, .here(available));
        }
    };

    // The calling thread only waits, so nothing is touched from two threads at
    // once.
    //
    // There is deliberately no fallback to the calling thread. Its stack size
    // is the host's choice, as little as 1 MiB, so the guard could not be told
    // honestly how much there is, and a program within section 7.2's
    // guarantees could fail or crash. Failing to start is the honest outcome.
    var task: Task = .{ .gpa = gpa, .source = source, .out = out };
    const thread = std.Thread.spawn(.{ .stack_size = stack_size }, Task.go, .{ &task, stack_size }) catch
        return error.StackUnavailable;
    thread.join();
    return task.result;
}

/// Runs each stage in order, stopping at the first that reports anything.
///
/// Stopping is deliberate. Section 17.2 asks for one primary error rather than a
/// cascade, and a parser fed a broken token stream produces exactly that cascade.
fn analyze(
    gpa: std.mem.Allocator,
    source: *const Source,
    out: ?*std.Io.Writer,
    stack: Interpreter.StackLimit,
) Error!Report {
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

    // The resolver's facts stay valid here: `resolved` is released only when
    // this function returns.
    var checked = try Checker.check(gpa, parsed.program, resolved.facts);
    defer checked.deinit();
    if (!checked.ok()) {
        const copies = try dupeDiagnostics(arena, checked.diagnostics);
        return .{ .arena_state = arena_state, .diagnostics = copies };
    }

    const writer = out orelse return .{ .arena_state = arena_state, .diagnostics = &.{} };

    var outcome = try Interpreter.run(gpa, source, parsed.program, &checked.signatures, writer, stack);
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
    const trace = try arena.alloc(Diagnostic.Frame, diagnostic.trace.len);
    for (diagnostic.trace, trace) |frame, *copy| {
        copy.* = .{ .function = try arena.dupe(u8, frame.function), .call_span = frame.call_span };
    }
    return .{
        .message = try arena.dupe(u8, diagnostic.message),
        .span = diagnostic.span,
        .help = try arena.dupe(u8, diagnostic.help),
        .trace = trace,
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
    _ = Type;
    _ = Checker;
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
    try expectOutput("print(-2 ** 2)\n", "-4\n");
    try expectOutput("print(2 ** 3 ** 2)\n", "512\n");
    try expectOutput("print((-2) ** 2)\n", "4\n");
    try expectOutput("print(2.0 ** -1)\n", "0.5\n");
}

test "exponentiation of two Ints is an Int, and a Float operand makes a Float" {
    try expectOutput("print(2 ** 10)\n", "1024\n");
    try expectOutput("var side = 7\nvar area: Int = side ** 2\nprint(area)\n", "49\n");
    try expectOutput("print(2 ** 0.5 > 1.41, 2.0 ** 3)\n", "true 8.0\n");
    try expectOutput("print(0 ** 0, (-1) ** 999999999999)\n", "1 -1\n");
    // The minimum Int is reachable exactly.
    try expectOutput("print((-2) ** 63)\n", "-9223372036854775808\n");
    try expectFailure("print(2 ** 63)\n", "exponentiation of 2 and 63 overflows Int");
    try expectFailure("print(2 ** -1)\n", "an Int cannot be raised to the negative power -1");
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

test "the minimum Int can be written, although its digits alone are out of range" {
    try expectOutput("print(-9223372036854775808)\n", "-9223372036854775808\n");
    try expectOutput("print(-9_223_372_036_854_775_808 + 1)\n", "-9223372036854775807\n");
    try expectFailure("print(9223372036854775808)\n", "this number is outside the range of Int");
    // `**` binds tighter than the minus, so the literal stands alone.
    try expectFailure("print(-9223372036854775808 ** 2)\n", "this number is outside the range of Int");
    // Negating it still overflows, because the range is asymmetric.
    try expectFailure("print(-(-9223372036854775808))\n", "negating -9223372036854775808 overflows Int");
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

test "a const needs its value where it is declared" {
    try expectFailure("const n: Int\n", "`n` is a `const`, so it needs a value where it is declared");
    try expectOutput("var n: Int\nn = 2\nprint(n)\n", "2\n");
}

test "compound assignment lowers through the matching operation" {
    try expectOutput("var n = 10\nn += 5\nprint(n)\n", "15\n");
    try expectOutput("var n = 10\nn -= 5\nprint(n)\n", "5\n");
    try expectOutput("var n = 10\nn *= 3\nprint(n)\n", "30\n");
    try expectOutput("var n = 7\nn //= 2\nprint(n)\n", "3\n");
    // `/=` follows `/`, which always produces a Float, so it needs a Float name.
    try expectOutput("var n = 10.0\nn /= 4\nprint(n)\n", "2.5\n");
    try expectFailure(
        "var n = 10\nn /= 4\n",
        "`/` produces Float, which `n` cannot hold because it is Int",
    );
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

test "every type has equality, and only numbers have order" {
    try expectOutput("print(true == true, true != false, false == true)\n", "true true false\n");
    try expectOutput("print(nothing == nothing, nothing != nothing)\n", "true false\n");
    try expectOutput("var done = 1 > 2\nprint(done == false)\n", "true\n");
    try expectFailure("print(true < false)\n", "`<` needs numbers, but these are Bool values");
    try expectFailure("print(nothing >= nothing)\n", "`>=` needs numbers, but these are Nothing values");
    try expectFailure("print(1 == true)\n", "Int and Bool cannot be compared");
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

// Section 4.1: static types, inference, and definite assignment.

test "a local is inferred from its initializer" {
    try expectOutput("var n = 1\nprint(n + 1)\n", "2\n");
    try expectFailure("var n = 1\nprint(not n)\n", "`not` needs a Bool, but this is Int");
}

test "an annotation is checked against the initializer" {
    try expectOutput("var n: Int = 1\nprint(n)\n", "1\n");
    try expectFailure("var n: Int = 1.5\n", "this is Float, but `n` was declared as Int");
    try expectFailure("var flag: Bool = 1\n", "this is Int, but `flag` was declared as Bool");
}

test "Int widens to Float in a declaration but Float does not narrow" {
    try expectOutput("var rate: Float = 1\nprint(rate)\n", "1.0\n");
    try expectFailure("var count: Int = 1.0\n", "this is Float, but `count` was declared as Int");
}

test "an unknown type name is rejected" {
    try expectFailure("var winner: Player\n", "`Player` is not a type");
}

test "an optional annotation is recognized but not yet available" {
    // The lexer hands over `Int?` as one identifier; the parser splits the
    // trailing `?` in type position, which is what makes this reachable.
    try expectFailure("var maybe: Int?\n", "optional types are not available yet");
}

test "an uninitialized variable needs an explicit type" {
    try expectFailure("var winner\n", "expected `=` after `winner`, found the end of the line");
}

test "reading before definite assignment is rejected" {
    try expectFailure("var n: Int\nprint(n)\n", "`n` may not have been assigned");
}

test "assignment on every branch proves definite assignment" {
    const program =
        \\var message: Int
        \\if 1 > 0 {
        \\    message = 1
        \\}
        \\else {
        \\    message = 2
        \\}
        \\print(message)
        \\
    ;
    try expectOutput(program, "1\n");
}

test "assignment on only one branch does not" {
    const program =
        \\var message: Int
        \\if 1 > 0 {
        \\    message = 1
        \\}
        \\print(message)
        \\
    ;
    try expectFailure(program, "`message` may not have been assigned");
}

test "an else-if chain without a final else proves nothing" {
    const program =
        \\var m: Int
        \\if 1 > 0 {
        \\    m = 1
        \\}
        \\else if 2 > 1 {
        \\    m = 2
        \\}
        \\print(m)
        \\
    ;
    try expectFailure(program, "`m` may not have been assigned");
}

test "operand errors are reported before execution rather than during it" {
    // Nothing is printed, because the program never starts.
    try expectFailure("print(1)\nprint(1 + true)\n", "addition needs numbers, but this is Int and Bool");
    try expectFailure("print(1)\nif 1 {\n  print(2)\n}\n", "a condition must be a Bool, but this is Int");
}

test "assignment checks the declared type" {
    try expectFailure("var n = 1\nn = true\n", "this is Bool, but `n` holds Int");
    try expectOutput("var rate = 1.0\nrate = 2\nprint(rate)\n", "2.0\n");
}

test "a compound assignment is checked through the operation it lowers to" {
    // `/` always produces a Float, so `/=` can never store into an Int.
    try expectFailure(
        "var count = 10\ncount /= 2\n",
        "`/` produces Float, which `count` cannot hold because it is Int",
    );
    try expectFailure("var n = 1\nn += true\n", "addition needs numbers, but this is Int and Bool");
}

test "one mistake produces one diagnostic rather than a cascade" {
    var source = try Source.init(testing.allocator, "test.em", "var n = 1 + true\nprint(n + 1)\nprint(n * 2)\n");
    defer source.deinit(testing.allocator);

    var report = try check(testing.allocator, &source);
    defer report.deinit();

    // The invalid type flows outward without being reported again.
    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
}

// Section 7: functions.

test "a function takes arguments and returns a value" {
    try expectOutput("func add(left: Int, right: Int): Int {\n    return left + right\n}\nprint(add(2, 3))\n", "5\n");
}

test "a function with no result may omit its return type" {
    try expectOutput("func greet(n: Int) {\n    print(n)\n}\ngreet(7)\n", "7\n");
    try expectOutput("func early(n: Int) {\n    if n > 0 {\n        return\n    }\n    print(n)\n}\nearly(1)\nearly(0)\n", "0\n");
}

test "a call with no result evaluates to nothing" {
    try expectOutput("func f() {\n    print(1)\n}\nvar result = f()\nprint(result)\n", "1\nnothing\n");
}

test "print evaluates every argument before writing any of them" {
    const functions =
        \\func first(): Int {
        \\    print(10)
        \\    return 1
        \\}
        \\func second(): Int {
        \\    print(20)
        \\    return 2
        \\}
        \\
    ;
    try expectOutput(functions ++ "print(first(), second())\n", "10\n20\n1 2\n");

    // An argument that fails leaves no half-written line behind.
    var source = try Source.init(testing.allocator, "test.em", "print(1, 1 // 0)\n");
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var report = try run(testing.allocator, &source, &out.writer);
    defer report.deinit();
    try testing.expect(report.failure != null);
    try testing.expectEqualStrings("", out.written());
}

/// Tracks the most memory live at once, to show that finished calls give theirs
/// back.
const PeakAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn record(self: *PeakAllocator, old_len: usize, new_len: usize) void {
        self.live = self.live - old_len + new_len;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.record(0, len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, len, ret)) return false;
        self.record(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const moved = self.child.rawRemap(memory, alignment, len, ret) orelse return null;
        self.record(memory.len, len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret);
        self.record(memory.len, 0);
    }
};

fn peakMemory(text: []const u8) !usize {
    var tracking: PeakAllocator = .{ .child = testing.allocator };
    const output = try runToString(tracking.allocator(), text);
    tracking.allocator().free(output);
    return tracking.peak;
}

test "memory stays flat however many calls a program makes" {
    // `calls(n)` makes 2^(n+1) - 1 calls but is never more than n + 1 deep.
    const program = "func calls(n: Int): Int {{\n    if n == 0 {{\n        return 1\n    }}\n    return calls(n - 1) + calls(n - 1)\n}}\nprint(calls({d}))\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{14}));
    // 32,767 calls against 15. Keeping a frame per call would cost megabytes.
    try testing.expect(many < few + 16 * 1024);
}

test "recursion and mutual recursion run when annotated" {
    const factorial =
        \\func factorial(n: Int): Int {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\print(factorial(10))
        \\
    ;
    try expectOutput(factorial, "3628800\n");

    const parity =
        \\func even?(n: Int): Bool {
        \\    if n == 0 {
        \\        return true
        \\    }
        \\    return odd?(n - 1)
        \\}
        \\func odd?(n: Int): Bool {
        \\    if n == 0 {
        \\        return false
        \\    }
        \\    return even?(n - 1)
        \\}
        \\print(even?(10), odd?(7))
        \\
    ;
    try expectOutput(parity, "true true\n");
}

test "functions are hoisted, so a call may come before the declaration" {
    try expectOutput("print(double(21))\nfunc double(n: Int): Int {\n    return n * 2\n}\n", "42\n");
}

test "a recursive function needs an explicit return type" {
    const program =
        \\func factorial(n: Int) {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\
    ;
    try expectFailure(program, "`factorial` is recursive and needs an explicit return type");

    // The same holds through a cycle of two.
    const cycle = "func a(n: Int) {\n    return b(n)\n}\nfunc b(n: Int) {\n    return a(n)\n}\n";
    try expectFailure(cycle, "`a` is recursive and needs an explicit return type");
}

test "a recursive function with no result needs no annotation" {
    // Its return type is `Nothing` without looking inside, so section 7.2 asks
    // for no annotation: there is nothing to infer circularly.
    try expectOutput("func countdown(n: Int) {\n    if n < 0 {\n        return\n    }\n    print(n)\n    countdown(n - 1)\n}\ncountdown(2)\n", "2\n1\n0\n");
}

test "a return type is inferred from a non-recursive body" {
    try expectOutput("func square(n: Int) {\n    return n * n\n}\nprint(square(6) + 1)\n", "37\n");
    // Section 4.4's widening applies when merging returns.
    try expectOutput("func pick(flag: Bool) {\n    if flag {\n        return 1\n    }\n    return 2.5\n}\nprint(pick(true), pick(false))\n", "1.0 2.5\n");
}

test "incompatible returns make an inferred type ambiguous" {
    try expectFailure(
        "func f(flag: Bool) {\n    if flag {\n        return 1\n    }\n    return true\n}\n",
        "the return type of `f` is ambiguous",
    );
    // A bare return alongside a valued one is Nothing beside a value.
    try expectFailure(
        "func f(flag: Bool) {\n    if flag {\n        return\n    }\n    return 1\n}\n",
        "the return type of `f` is ambiguous",
    );
}

test "every path in a value-producing function must return" {
    try expectFailure("func f(n: Int): Int {\n    if n > 0 {\n        return 1\n    }\n}\n", "not every path in `f` returns a value");
    try expectOutput("func sign(n: Int): Int {\n    if n > 0 {\n        return 1\n    }\n    else if n < 0 {\n        return -1\n    }\n    else {\n        return 0\n    }\n}\nprint(sign(-5))\n", "-1\n");
}

test "return is checked against the function's type" {
    try expectFailure("func f(): Int {\n    return true\n}\n", "this is Bool, but the function returns Int");
    try expectFailure("func f(): Int {\n    return\n}\n", "this function must return a value");
    try expectFailure("func f(): Nothing {\n    return 1\n}\n", "this function returns Nothing, so `return` cannot produce a value");
    try expectFailure("print(1)\nreturn\n", "`return` can only be used inside a function");
    try expectOutput("func half(n: Int): Float {\n    return n\n}\nprint(half(3))\n", "3.0\n");
}

test "calls are checked for arity and argument types" {
    const add = "func add(a: Int, b: Int): Int {\n    return a + b\n}\n";
    try expectFailure(add ++ "print(add(1))\n", "`add` takes 2 arguments, but this call passes 1");
    try expectFailure(add ++ "print(add(1, true))\n", "this is Bool, but parameter `b` of `add` needs Int");
    // Int widens to a Float parameter.
    try expectOutput("func show(x: Float) {\n    print(x)\n}\nshow(2)\n", "2.0\n");
}

test "only a function can be called, and a function cannot yet be a value" {
    try expectFailure("var x = 5\nprint(x())\n", "`x` is not a function");
    try expectFailure("func f(): Int {\n    return 1\n}\nvar g = f\n", "`f` is a function, and functions cannot be used as values yet");
}

test "parameters are read-only and share the body's scope" {
    try expectFailure("func f(n: Int) {\n    n = 5\n}\n", "`n` cannot be reassigned");
    try expectFailure("func f(n: Int) {\n    var n = 5\n}\n", "`n` is already declared");
    try expectFailure("func f(n: Int, n: Int) {\n}\n", "`n` is already a parameter");
}

test "a function sees module variables declared above it" {
    try expectOutput("const limit = 10\nfunc clamp(n: Int): Int {\n    if n > limit {\n        return limit\n    }\n    return n\n}\nprint(clamp(25), clamp(3))\n", "10 3\n");
    try expectFailure("func show() {\n    print(limit)\n}\nconst limit = 10\n", "`limit` is not declared until later in the file");
}

test "a function may update module state" {
    try expectOutput("var count = 0\nfunc bump() {\n    count += 1\n}\nbump()\nbump()\nprint(count)\n", "2\n");
    try expectFailure("const limit = 1\nfunc f() {\n    limit = 2\n}\n", "`limit` cannot be reassigned");
}

test "crossing a function boundary allows reusing a module-level name" {
    try expectOutput("const n = 100\nfunc twice(n: Int): Int {\n    return n * 2\n}\nprint(twice(4), n)\n", "8 100\n");
}

test "functions and variables share one namespace" {
    try expectFailure("var greet = 1\nfunc greet() {\n}\n", "`greet` is already declared");
    try expectFailure("func f() {\n}\nfunc f() {\n}\n", "`f` is already declared");
    try expectFailure("func f() {\n}\nf = 1\n", "`f` is a function and cannot be assigned to");
}

test "a program function shadows a prelude function" {
    try expectOutput("func print(n: Int) {\n}\nprint(1)\n", "");
}

test "hoisting never permits reading an uninitialized captured variable" {
    try expectFailure(
        "print(area(2.0))\nconst pi = 3.14159\nfunc area(r: Float): Float {\n    return pi * r * r\n}\n",
        "`area` reads `pi`, which is not assigned yet here",
    );
    // Through another function.
    try expectFailure(
        "func outer(): Int {\n    return inner()\n}\nprint(outer())\nvar limit = 5\nfunc inner(): Int {\n    return limit\n}\n",
        "`outer` reads `limit`, which is not assigned yet here",
    );
    // A variable assigned on the path that makes the call.
    try expectOutput(
        "var ready: Int\nif 1 > 0 {\n    ready = 1\n    report()\n}\nfunc report() {\n    print(ready)\n}\n",
        "1\n",
    );
    // A plain assignment in the function needs no earlier value.
    try expectOutput("var total: Int\nfunc reset() {\n    total = 0\n}\nreset()\nprint(1)\n", "1\n");
}

test "nested functions are deferred, with one diagnostic" {
    var source = try Source.init(testing.allocator, "test.em", "if true {\n    func helper() {\n        print(1)\n    }\n}\n");
    defer source.deinit(testing.allocator);
    var report = try check(testing.allocator, &source);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try testing.expectEqualStrings("nested functions are not available yet", report.diagnostics[0].message);
}

test "an early return leaves a branch out of definite assignment" {
    const program =
        \\func classify(n: Int): Int {
        \\    var label: Int
        \\    if n > 0 {
        \\        label = 1
        \\    }
        \\    else {
        \\        return 0
        \\    }
        \\    return label
        \\}
        \\print(classify(5), classify(-5))
        \\
    ;
    try expectOutput(program, "1 0\n");
}

test "a runtime error inside a function carries its stack trace" {
    const program =
        \\func divide(left: Int, right: Int): Float {
        \\    return left / right
        \\}
        \\func ratio(n: Int): Float {
        \\    return divide(n, 0)
        \\}
        \\print(ratio(4))
        \\
    ;
    var source = try Source.init(testing.allocator, "main.em", program);
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var report = try run(testing.allocator, &source, &out.writer);
    defer report.deinit();

    const rendered = try report.failure.?.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.em:2:12: division by zero
        \\      return left / right
        \\             ^^^^^^^^^^^^
        \\Check the divisor before dividing. Division by zero has no result for either numeric type.
        \\in `divide`, called at main.em:5:12
        \\in `ratio`, called at main.em:7:7
        \\
    , rendered);
}

test "unbounded recursion is caught at the limit, with repeated frames summarized" {
    const program =
        \\func forever(n: Int): Int {
        \\    return forever(n + 1)
        \\}
        \\print(forever(0))
        \\
    ;
    var source = try Source.init(testing.allocator, "main.em", program);
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var report = try run(testing.allocator, &source, &out.writer);
    defer report.deinit();

    const failure = report.failure.?;
    try testing.expectEqualStrings("too much recursion calling `forever`", failure.message);
    // Exactly the 1,000 active calls section 7.2 guarantees.
    try testing.expectEqual(@as(usize, 1000), failure.trace.len);

    const rendered = try failure.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.endsWith(u8, rendered,
        \\in `forever`, called at main.em:2:12 (999 times)
        \\in `forever`, called at main.em:4:7
        \\
    ));
}

test "a body nested 250 deep still supports 1,000 calls" {
    // Section 7.2's call guarantee has to hold at section 3.4's nesting
    // guarantee, in whichever build mode the tests run.
    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(testing.allocator);
    for (0..250) |_| try expression.appendSlice(testing.allocator, "0 + (");
    try expression.appendSlice(testing.allocator, "deep(n - 1)");
    for (0..250) |_| try expression.append(testing.allocator, ')');

    const program = try std.fmt.allocPrint(
        testing.allocator,
        "func deep(n: Int): Int {{\n    if n == 0 {{\n        return 0\n    }}\n    return {s}\n}}\nprint(deep(999))\n",
        .{expression.items},
    );
    defer testing.allocator.free(program);
    try expectOutput(program, "0\n");
}

test "section 3.4: 256 levels of nesting are accepted and the 257th is reported" {
    const allocator = testing.allocator;
    for ([_]usize{ 255, 256 }) |depth| {
        // `print(` is one level, so this makes `depth` in total.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendSlice(allocator, "print(");
        for (0..depth - 1) |_| try text.append(allocator, '(');
        try text.append(allocator, '1');
        for (0..depth) |_| try text.append(allocator, ')');
        try text.append(allocator, '\n');

        if (depth == 256) {
            try expectOutput(text.items, "1\n");
            // One more level.
            try text.insert(allocator, 6, '(');
            try text.insert(allocator, text.items.len - 1, ')');
            try expectFailure(text.items, "this is nested too deeply");
        }
    }
}

test "a long flat chain is a diagnostic, not a crash" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "print(1");
    for (0..Parser.max_expression_depth) |_| try text.appendSlice(testing.allocator, " + 1");
    try text.appendSlice(testing.allocator, ")\n");
    try expectFailure(text.items, "this expression is too long");
}
