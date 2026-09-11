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
pub const Heap = @import("Heap.zig");
pub const unicode = @import("unicode.zig");
pub const strings = @import("strings.zig");

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

/// Where a running program's output goes and where `input` reads from.
pub const Streams = struct {
    out: *std.Io.Writer,
    in: *std.Io.Reader,
};

/// Checks a source file and then executes it with `streams`.
pub fn run(gpa: std.mem.Allocator, source: *const Source, streams: Streams) Error!Report {
    return onLargeStack(gpa, source, streams);
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

fn onLargeStack(gpa: std.mem.Allocator, source: *const Source, streams: ?Streams) Error!Report {
    const Task = struct {
        gpa: std.mem.Allocator,
        source: *const Source,
        streams: ?Streams,
        result: Error!Report = undefined,

        fn go(task: *@This(), available: usize) void {
            task.result = analyze(task.gpa, task.source, task.streams, .here(available));
        }
    };

    // The calling thread only waits, so nothing is touched from two threads at
    // once.
    //
    // There is deliberately no fallback to the calling thread. Its stack size
    // is the host's choice, as little as 1 MiB, so the guard could not be told
    // honestly how much there is, and a program within section 7.2's
    // guarantees could fail or crash. Failing to start is the honest outcome.
    var task: Task = .{ .gpa = gpa, .source = source, .streams = streams };
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
    streams: ?Streams,
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

    const running = streams orelse return .{ .arena_state = arena_state, .diagnostics = &.{} };

    var outcome = try Interpreter.run(
        gpa,
        source,
        parsed.program,
        &checked.signatures,
        &checked.literal_types,
        running.out,
        running.in,
        stack,
    );
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
    _ = Heap;
    _ = unicode;
    _ = strings;
}

/// Runs a program and returns what it printed. The caller owns the result.
fn runToString(gpa: std.mem.Allocator, text: []const u8, input: []const u8) ![]u8 {
    var source = try Source.init(gpa, "test.em", text);
    defer source.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var no_input: std.Io.Reader = .fixed(input);
    var report = try run(gpa, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    if (!report.ok()) {
        const problem = if (report.failure) |failure| failure else report.diagnostics[0];
        std.debug.print("unexpected: {s}\n", .{problem.message});
        return error.UnexpectedDiagnostic;
    }

    return out.toOwnedSlice();
}

fn expectOutput(text: []const u8, expected: []const u8) !void {
    return expectOutputWithInput(text, "", expected);
}

/// Runs a program that reads `input` through `input()`.
fn expectOutputWithInput(text: []const u8, input: []const u8, expected: []const u8) !void {
    const actual = try runToString(testing.allocator, text, input);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectFailure(text: []const u8, expected_message: []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
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

// Section 6.4: loops.

test "a for loop visits a range in order, and a range only counts upward" {
    try expectOutput("for i in 1..3 {\n    print(i)\n}\n", "1\n2\n3\n");
    try expectOutput("for i in 0..<3 {\n    print(i)\n}\n", "0\n1\n2\n");
    // A start past the end is empty, so computed bounds cannot reverse.
    try expectOutput("var count = 0\nfor i in 0..count - 1 {\n    print(i)\n}\nprint(9)\n", "9\n");
    // Written with two literals, a descending range can only be a mistake.
    try expectFailure("for i in 5..1 {\n    print(i)\n}\n", "this range is empty, because ranges count upward");
    try expectFailure("for i in -1..-3 {\n    print(i)\n}\n", "this range is empty, because ranges count upward");
    try expectOutput("for i in 3..<3 {\n    print(i)\n}\nprint(9)\n", "9\n");
    try expectOutput("for i in 3..3 {\n    print(i)\n}\n", "3\n");
}

test "counting down, stepping, and reversing say their direction in words" {
    const program =
        \\var out: [Int] = []
        \\for i in 5.down_to(1) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in 10.down_to(0).step(4) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in (0..10).step(3) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in (1..4).reverse() {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in 2.up_to(4) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\
    ;
    try expectOutput(program, "[5, 4, 3, 2, 1]\n[10, 6, 2]\n[0, 3, 6, 9]\n[4, 3, 2, 1]\n[2, 3, 4]\n");
}

test "reverse and step apply in the order written" {
    try expectOutput("for i in (0..10).step(3).reverse() {\n    print(i)\n}\n", "9\n6\n3\n0\n");
    try expectOutput("for i in (0..10).reverse().step(3) {\n    print(i)\n}\n", "10\n7\n4\n1\n");
}

test "a computed count on the wrong side is empty, so walking backwards is safe" {
    try expectOutput("var count = 0\nfor i in count.down_to(1) {\n    print(i)\n}\nprint(9)\n", "9\n");
    try expectOutput(
        "var items: [Int] = []\nfor i in (0..<items.count).reverse() {\n    print(items[i])\n}\nprint(9)\n",
        "9\n",
    );
}

test "counting reaches both ends of the Int range without overflowing" {
    try expectOutput(
        "for i in 9223372036854775807.down_to(9223372036854775804).step(2) {\n    print(i)\n}\n",
        "9223372036854775807\n9223372036854775805\n",
    );
    try expectOutput(
        "for i in (-9223372036854775807).down_to(-9223372036854775807 - 1) {\n    print(i)\n}\n",
        "-9223372036854775807\n-9223372036854775808\n",
    );
}

test "a count written with literals that can only be empty is an error" {
    try expectFailure("for i in 1.down_to(10) {\n    print(i)\n}\n", "this is empty, because `down_to` only counts down");
    try expectFailure("for i in 10.up_to(1) {\n    print(i)\n}\n", "this is empty, because `up_to` only counts up");
}

test "a step is at least 1 and given once" {
    try expectFailure("for i in (1..5).step(0) {\n    print(i)\n}\n", "a step must be at least 1");
    try expectFailure("var n = -2\nfor i in (1..5).step(n) {\n    print(i)\n}\n", "a step must be at least 1, but this is -2");
    try expectFailure("for i in (1..9).step(2).reverse().step(2) {\n    print(i)\n}\n", "this already has a step");
    try expectFailure("var countdown = 10.down_to(1)\n", "a range can only be looped over so far");
}

test "a range may end at the largest Int without overflowing" {
    try expectOutput(
        "for i in 9223372036854775806..9223372036854775807 {\n    print(i)\n}\n",
        "9223372036854775806\n9223372036854775807\n",
    );
}

test "range endpoints are evaluated once, before the first iteration" {
    const program =
        \\var calls = 0
        \\func limit(): Int {
        \\    calls += 1
        \\    return 3
        \\}
        \\for i in 1..limit() {
        \\    print(i)
        \\}
        \\print(calls)
        \\
    ;
    try expectOutput(program, "1\n2\n3\n1\n");
}

test "an underscore visits each value without naming it" {
    try expectOutput("for _ in 1..3 {\n    print(0)\n}\n", "0\n0\n0\n");
}

test "while repeats until its condition is false" {
    try expectOutput("var n = 3\nwhile n > 0 {\n    print(n)\n    n -= 1\n}\n", "3\n2\n1\n");
    try expectOutput("while false {\n    print(1)\n}\nprint(2)\n", "2\n");
}

test "break and continue act on the innermost loop" {
    const program =
        \\for row in 1..3 {
        \\    for column in 1..3 {
        \\        continue if column == 2
        \\        break if column > row
        \\        print(row * 10 + column)
        \\    }
        \\}
        \\
    ;
    try expectOutput(program, "11\n21\n31\n33\n");
}

test "a local declared in a loop body is fresh every iteration" {
    try expectOutput("for i in 1..2 {\n    var doubled = i * 2\n    print(doubled)\n}\n", "2\n4\n");
}

test "after while true, a name is assigned when every break assigned it" {
    const assigned =
        \\var found: Int
        \\var n = 0
        \\while true {
        \\    n += 1
        \\    if n * n > 50 {
        \\        found = n
        \\        break
        \\    }
        \\}
        \\print(found)
        \\
    ;
    try expectOutput(assigned, "8\n");

    const not_on_every_break =
        \\var found: Int
        \\var n = 0
        \\while true {
        \\    n += 1
        \\    break if n > 9
        \\    found = n
        \\    break if n > 3
        \\}
        \\print(found)
        \\
    ;
    try expectFailure(not_on_every_break, "`found` may not have been assigned");
}

test "a loop may run zero times, so what it assigns is not known after it" {
    try expectFailure(
        "var x: Int\nvar n = 0\nwhile n < 3 {\n    x = n\n    n += 1\n}\nprint(x)\n",
        "`x` may not have been assigned",
    );
    try expectFailure(
        "var x: Int\nfor i in 1..3 {\n    x = i\n}\nprint(x)\n",
        "`x` may not have been assigned",
    );
}

test "a function may end in a loop that only a return leaves" {
    const program =
        \\func first_multiple(of: Int, above: Int): Int {
        \\    var n = above + 1
        \\    while true {
        \\        return n if n % of == 0
        \\        n += 1
        \\    }
        \\}
        \\print(first_multiple(7, 20))
        \\
    ;
    try expectOutput(program, "21\n");

    // Any other loop can finish, so the path after it still needs a return.
    try expectFailure(
        "func f(n: Int): Int {\n    while n > 0 {\n        return 1\n    }\n}\n",
        "not every path in `f` returns a value",
    );
}

test "break and continue only work inside a loop" {
    try expectFailure("break\n", "`break` can only be used inside a loop");
    try expectFailure("func f() {\n    continue\n}\n", "`continue` can only be used inside a loop");
    // A function body is not inside the loop that calls it.
    try expectFailure("func f() {\n    break\n}\nfor i in 1..2 {\n    f()\n}\n", "`break` can only be used inside a loop");
}

test "a loop variable is read-only and does not outlive its loop" {
    try expectFailure("for i in 1..3 {\n    i = 2\n}\n", "`i` cannot be reassigned");
    try expectFailure("for i in 1..3 {\n    print(i)\n}\nprint(i)\n", "`i` is not defined");
    try expectFailure("var i = 0\nfor i in 1..3 {\n    print(i)\n}\n", "`i` is already declared");
}

test "only an Int range can be looped over so far" {
    try expectFailure("for i in 1..2.5 {\n    print(i)\n}\n", "counting works with whole numbers, but this is Float");
    try expectFailure("for i in 5 {\n    print(i)\n}\n", "a `for` loop cannot visit Int");
    try expectFailure("var r = 1..3\n", "a range can only be looped over so far");
    try expectFailure("for i in 1..2..3 {\n    print(i)\n}\n", "a range has one start and one end");
}

test "memory stays flat however many times a loop runs" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var part = i * 2\n    total += part\n}}\nprint(total)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{20_000}));
    try testing.expect(many < few + 16 * 1024);
}

// Section 6.2: the trailing `if`.

test "a trailing if guards one statement" {
    try expectOutput("print(1) if true\nprint(2) if false\n", "1\n");
    try expectOutput("var score = 5\nscore += 10 if score > 3\nprint(score)\n", "15\n");
    try expectOutput(
        "func sign(n: Int): Int {\n    return -1 if n < 0\n    return 0 if n == 0\n    return 1\n}\nprint(sign(-4), sign(0), sign(9))\n",
        "-1 0 1\n",
    );
    try expectOutput("func greet(ready: Bool) {\n    return if not ready\n    print(1)\n}\ngreet(false)\ngreet(true)\n", "1\n");
}

test "a declaration cannot have a trailing if" {
    try expectFailure("var x = 1 if true\n", "a declaration cannot have a trailing `if`");
}

// Section 8: lists.

test "a list literal, indexing, and count" {
    try expectOutput("var scores = [10, 20, 30]\nprint(scores, scores.count, scores[0], scores[2])\n", "[10, 20, 30] 3 10 30\n");
    try expectOutput("print([[1, 2], [3]], [[1, 2], [3]][1][0])\n", "[[1, 2], [3]] 3\n");
    // A trailing comma is allowed, and newlines inside the brackets continue it.
    try expectOutput("var xs = [\n    1,\n    2,\n]\nprint(xs)\n", "[1, 2]\n");
}

test "an empty list takes its type from context" {
    try expectOutput("var names: [Int] = []\nprint(names, names.empty?())\n", "[] true\n");
    try expectOutput("func none(): [Int] {\n    return []\n}\nprint(none())\n", "[]\n");
    try expectOutput("var xs = [1]\nprint(xs == [], [] != xs)\n", "false true\n");
    try expectFailure("var names = []\n", "an empty list needs a type");
}

test "a list of Ints and Floats is a list of Floats, and a Float list widens what it stores" {
    try expectOutput("print([1, 2.5])\n", "[1.0, 2.5]\n");
    try expectOutput("var rates: [Float] = [1, 2]\nrates.append(3)\nrates[0] = 4\nprint(rates)\n", "[4.0, 2.0, 3.0]\n");
    try expectOutput("var grid: [[Float]] = [[1], [2]]\nprint(grid)\n", "[[1.0], [2.0]]\n");
    try expectFailure("var xs = [1, true]\n", "this is Bool, but the list holds Int");
}

test "lists are invariant, so an Int list is not a Float list" {
    try expectFailure("var ints = [1]\nvar floats: [Float] = ints\n", "this is [Int], but `floats` was declared as [Float]");
    try expectFailure("print([1] == [1.0])\n", "[Int] and [Float] cannot be compared");
}

test "assigning a list gives an independent copy" {
    try expectOutput(
        "var original = [1, 2]\nvar copy = original\ncopy.append(3)\ncopy[0] = 9\nprint(original, copy)\n",
        "[1, 2] [9, 2, 3]\n",
    );
    // Nested lists are copied too, at whatever depth the change happens.
    try expectOutput(
        "var rows = [[1], [2]]\nvar copy = rows\ncopy[0].append(9)\ncopy[1][0] = 5\nprint(rows, copy)\n",
        "[[1], [2]] [[1, 9], [5]]\n",
    );
}

test "a list passed to a function is independent of the caller's" {
    const program =
        \\var scores = [1]
        \\func show(items: [Int]) {
        \\    scores.append(2)
        \\    print(items)
        \\}
        \\show(scores)
        \\print(scores)
        \\
    ;
    try expectOutput(program, "[1]\n[1, 2]\n");

    const returned =
        \\func with_guest(guests: [Int], guest: Int): [Int] {
        \\    var updated = guests
        \\    updated.append(guest)
        \\    return updated
        \\}
        \\var party = [1, 2]
        \\var bigger = with_guest(party, 3)
        \\print(party, bigger)
        \\
    ;
    try expectOutput(returned, "[1, 2] [1, 2, 3]\n");
}

test "a loop visits the list as it was when the loop began" {
    try expectOutput(
        "var items = [1, 2]\nfor item in items {\n    items.append(item * 10)\n}\nprint(items)\n",
        "[1, 2, 10, 20]\n",
    );
    try expectOutput("var total = 0\nfor value in [5, 6, 7] {\n    total += value\n}\nprint(total)\n", "18\n");
}

test "element assignment, including compound" {
    try expectOutput("var xs = [1, 2]\nxs[1] += 10\nxs[0] *= 3\nprint(xs)\n", "[3, 12]\n");
    try expectOutput("var grid = [[1, 2], [3, 4]]\ngrid[1][0] = 30\nprint(grid)\n", "[[1, 2], [30, 4]]\n");
}

test "the essential list methods" {
    const program =
        \\var xs = [3, 1, 3, 2, 3]
        \\xs.remove(3)
        \\print(xs)
        \\xs.remove_all(3)
        \\print(xs)
        \\xs.insert(0, 7)
        \\xs.insert(xs.count, 8)
        \\print(xs)
        \\print(xs.remove_at(1), xs)
        \\print(xs.remove_first(), xs.remove_last(), xs)
        \\print(xs.contains?(2), xs.contains?(9))
        \\xs.clear()
        \\print(xs, xs.count, xs.empty?())
        \\xs.remove(4)
        \\print(xs)
        \\
    ;
    try expectOutput(program, "[1, 3, 2, 3]\n[1, 2]\n[7, 1, 2, 8]\n1 [7, 2, 8]\n7 8 [2]\ntrue false\n[] 0 true\n[]\n");
}

test "lists compare element by element and print as they are written" {
    try expectOutput("print([1, 2] == [1, 2], [1, 2] != [2, 1], [[1]] == [[1]])\n", "true true true\n");
    try expectOutput("print([true, false], [0.5])\n", "[true, false] [0.5]\n");
}

test "an index outside the list names the index and the valid range" {
    try expectFailure("var xs = [1, 2, 3]\nprint(xs[3])\n", "index 3 is outside this list, which has 3 elements");
    try expectFailure("var xs = [1]\nxs[-1] = 0\n", "index -1 is outside this list, which has 1 element");
    try expectFailure("var xs: [Int] = []\nprint(xs[0])\n", "index 0 is outside this list, which is empty");
    try expectFailure("var xs = [1]\nxs.insert(3, 2)\n", "cannot insert at index 3 in a list of 1 element");
    try expectFailure("var xs: [Int] = []\nprint(xs.remove_last())\n", "cannot remove an element from an empty list");
}

test "a const, a parameter, a loop variable, and a temporary cannot change" {
    try expectFailure("const xs = [1]\nxs.append(2)\n", "`xs` is a `const`, so its contents cannot change");
    try expectFailure("const xs = [1]\nxs[0] = 2\n", "`xs` is a `const`, so its contents cannot change");
    try expectFailure(
        "func f(guests: [Int]) {\n    guests.append(1)\n}\n",
        "`guests` is a parameter, so a change to it would be lost when the function returns",
    );
    try expectFailure(
        "var grid = [[1]]\nfor row in grid {\n    row[0] = 2\n}\n",
        "`row` is a loop variable, so a change to it would be lost",
    );
    try expectFailure(
        "func make(): [Int] {\n    return [1]\n}\nmake().append(2)\n",
        "`append` changes a list, but this list is a temporary value, so the change would be lost",
    );
    // Reading through a const or a parameter is fine.
    try expectOutput("const xs = [1, 2]\nprint(xs.contains?(2), xs[1], xs.count)\n", "true 2 2\n");
}

test "a misspelled member names what Emerald calls it" {
    try expectFailure("var xs = [1]\nxs.push(2)\n", "[Int] has no method `push`");
    try expectFailure("var xs = [1]\nprint(xs.length)\n", "[Int] has no property `length`");
    try expectFailure("var xs = [1]\nprint(xs.count())\n", "`count` is a property, so it takes no parentheses");
    try expectFailure("var xs = [1]\nprint(xs.append)\n", "`append` is a method, so it needs parentheses");
    try expectFailure("var n = 5\nprint(n[0])\n", "Int cannot be indexed");
    try expectFailure("var xs = [1]\nprint(xs[true])\n", "an index must be an Int, but this is Bool");
}

test "memory stays flat however many lists a loop builds and drops" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var row = [i, i, i]\n    row.append(i)\n    var copy = row\n    copy[0] = 0\n    total += copy.count\n}}\nprint(total)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{5_000}));
    try testing.expect(many < few + 16 * 1024);
}

// Section 9: strings.

test "string literals: escapes, raw strings, and code points" {
    try expectOutput("print(\"a\\tb\\\\c \\\"q\\\" \\#{x}\")\n", "a\tb\\c \"q\" #{x}\n");
    try expectOutput("print('C:\\Users\\raw \\n')\n", "C:\\Users\\raw \\n\n");
    try expectOutput("print(\"caf\\u{E9} \\u{1F600}\")\n", "caf\u{E9} \u{1F600}\n");
    try expectFailure("print(\"\\u{D800}\")\n", "this `\\u` escape is not a Unicode character");
    try expectFailure("print(\"\\u0301\")\n", "this `\\u` escape is incomplete");
}

test "interpolation displays any value, and strings inside lists are quoted" {
    try expectOutput("var n = 3\nprint(\"n is #{n}, half is #{n / 2}, #{n > 2}\")\n", "n is 3, half is 1.5, true\n");
    try expectOutput("var n = 3\nprint(\"outer #{\"inner #{n + 1}\"} end\")\n", "outer inner 4 end\n");
    try expectOutput("print(\"#{[\"a, b\", \"c\"]}\")\n", "[\"a, b\", \"c\"]\n");
    try expectOutput("print([\"q\\\"\", \"line\\n\"])\n", "[\"q\\\"\", \"line\\n\"]\n");
    try expectFailure("print(\"#{}\")\n", "an interpolation needs an expression");
    try expectFailure("print(\"a #{1 + 2\")\n", "this `#{` is never closed");
}

test "a triple-quoted string removes the closing delimiter's indentation" {
    const program =
        \\var text = """
        \\    first
        \\      indented
        \\
        \\    last #{1 + 1}
        \\    """
        \\print(text)
        \\print(text.lines().count)
        \\
    ;
    try expectOutput(program, "first\n  indented\n\nlast 2\n4\n");
    // A Windows line ending becomes `\n`.
    try expectOutput("var text = \"\"\"\r\n  a\r\n  b\r\n  \"\"\"\r\nprint(text.count)\r\n", "3\n");
    try expectFailure("var s = \"\"\"text\"\"\"\n", "a triple-quoted string starts on the line after its `\"\"\"`");
    try expectFailure("var s = \"\"\"\n  text\"\"\"\n", "the closing `\"\"\"` of this string needs a line of its own");
    try expectFailure("var s = \"\"\"\n  a\n    \"\"\"\n", "this line is indented less than the closing `\"\"\"`");
}

test "count, indexing, and for measure characters, not bytes" {
    try expectOutput("var s = \"h\\u{E9}llo \\u{1F44B}\"\nprint(s.count, s[1], s[6])\n", "7 \u{E9} \u{1F44B}\n");
    // `e` and a combining accent are one character.
    try expectOutput("for c in \"e\\u{301}x\" {\n    write(c, \"|\")\n}\nprint()\n", "e\u{301} |x |\n");
    try expectFailure("print(\"abc\"[3])\n", "index 3 is outside this String, which has 3 characters");
    try expectFailure("var s = \"abc\"\ns[0] = \"x\"\n", "a String cannot be changed in place");
}

test "strings compare by canonical equivalence and order by code point" {
    try expectOutput("print(\"caf\\u{E9}\" == \"cafe\\u{301}\", \"a\" != \"b\")\n", "true true\n");
    try expectOutput("print(\"apple\" < \"banana\", \"Zebra\" < \"apple\", \"b\" >= \"b\")\n", "true true true\n");
    try expectOutput("print([\"caf\\u{E9}\"].contains?(\"cafe\\u{301}\"))\n", "true\n");
}

test "plus joins strings, and nothing else mixes text with arithmetic" {
    try expectOutput("var s = \"a\"\ns += \"b\"\ns = s + \"c\"\nprint(s)\n", "abc\n");
    try expectOutput("var names = [\"x\"]\nnames[0] += \"y\"\nprint(names)\n", "[\"xy\"]\n");
    try expectFailure("print(\"n = \" + 3)\n", "`+` joins two Strings, but this is String and Int");
    try expectFailure("print(\"a\" - \"b\")\n", "subtraction needs numbers, but this is String and String");
}

test "the string vocabulary" {
    try expectOutput("print(\"Stra\\u{DF}e\".upper(), \"ABC\".lower(), \"\\u{E9}lan\".capitalize())\n", "STRASSE abc \u{C9}lan\n");
    try expectOutput("print(\"  hi  \".trim() + \"|\", \"  hi  \".trim_start() + \"|\", \"  hi  \".trim_end() + \"|\")\n", "hi| hi  |   hi|\n");
    try expectOutput("print(\"caf\\u{E9}\".contains?(\"e\"), \"cafe\".contains?(\"e\"), \"ab\".starts_with?(\"a\"), \"ab\".ends_with?(\"b\"))\n", "false true true true\n");
    try expectOutput("print(\"a,b,,c\".split(\",\"), \"one\\ntwo\\n\".lines(), \"ab\".chars())\n", "[\"a\", \"b\", \"\", \"c\"] [\"one\", \"two\"] [\"a\", \"b\"]\n");
    try expectOutput("print(\"ha\".repeat(3), \"stressed\".reverse(), \"a-b-c\".replace(\"-\", \"+\"))\n", "hahaha desserts a+b+c\n");
    try expectOutput("print(\"hello\".substring(1), \"hello\".substring(1, 3), \"hello\".substring(5) == \"\")\n", "ello ell true\n");
    try expectOutput("print(\" \".blank?(), \"\".empty?(), \"a\".empty?())\n", "true true false\n");
    try expectFailure("print(\"abc\".substring(1, 5))\n", "a substring of 5 characters from 1 runs past the end of a String of 3");
    try expectFailure("print(\"abc\".split(\"\"))\n", "`split` needs a separator, but this is an empty String");
    try expectFailure("print(\"abc\".length)\n", "String has no property `length`");
}

test "converting between strings and numbers" {
    try expectOutput("print(\"42\".to_int() + 1, \" -7 \".to_int(), \"x\".to_int_or(-1))\n", "43 -7 -1\n");
    try expectOutput("print(\"2.5\".to_float(), \"3\".to_float(), \"no\".to_float_or(0))\n", "2.5 3.0 0.0\n");
    try expectOutput("print(12.to_string() + \"!\", 2.0.to_string(), false.to_string())\n", "12! 2.0 false\n");
    try expectFailure("print(\"4 2\".to_int())\n", "\"4 2\" is not a whole number");
    try expectFailure("print(\"99999999999999999999\".to_int())\n", "\"99999999999999999999\" is outside the range of Int");
}

test "the first program: input and interpolation" {
    const program = "var name = input(\"What is your name? \")\nprint(\"Hello, #{name}!\")\n";
    try expectOutputWithInput(program, "Ada\n", "What is your name? Hello, Ada!\n");
    // A Windows line ending is removed with the newline; Enter alone gives "".
    try expectOutputWithInput("print(input().count, input().count)\n", "ab\r\n\n", "2 0\n");
    // The last line may end without a newline.
    try expectOutputWithInput("print(input())\n", "last", "last\n");
    try expectFailure("var name = input()\n", "`input` reached the end of the input");
    try expectOutput("write(\"a\", \"b\")\nwrite(\"c\")\nprint()\n", "a bc\n");
}

test "names follow Unicode identifier rules and normalize" {
    try expectOutput("var \u{FC}ber = 1\nprint(\u{FC}ber)\n", "1\n");
    // A precomposed and a decomposed spelling are the same name (3.3).
    try expectOutput("var caf\u{E9} = 2\nprint(cafe\u{301})\n", "2\n");
    try expectFailure("var \u{1F600} = 1\n", "this character cannot be used in a name");
}

test "memory stays flat however many strings a loop builds and drops" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var line = \"item #{{i}}: \" + i.to_string()\n    total += line.upper().count\n}}\nprint(total > 0)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{5_000}));
    try testing.expect(many < few + 16 * 1024);
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
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
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
    const output = try runToString(tracking.allocator(), text, "");
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
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
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
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
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
