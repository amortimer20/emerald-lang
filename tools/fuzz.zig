//! A bounded, deterministic frontend-and-execution fuzz runner.
//!
//!     zig build fuzz -Doptimize=ReleaseSafe -- [seed] [cases]
//!
//! Inputs are always valid UTF-8 source text, but are intentionally not always
//! valid Emerald. Every input must lex and parse without crashing or producing
//! an unbounded diagnostic cascade. Inputs accepted by both stages also reach
//! the checker, which must not crash either, and are formatted twice;
//! formatting must keep them parseable and be idempotent. A checked program
//! also runs with a fixed interpreter-step budget and discarded output. The
//! budget is an uncatchable host boundary, so future generated loops cannot
//! hang the campaign or accumulate unbounded output.

const std = @import("std");
const emerald = @import("emerald");

const default_seed: u64 = 12_648_430;
const default_cases: usize = 1_000;
const max_execution_steps: usize = 100;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 3) usage();

    const seed = if (args.len >= 2)
        std.fmt.parseInt(u64, args[1], 10) catch usage()
    else
        default_seed;
    const cases = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch usage()
    else
        default_cases;

    var seeds = std.Random.DefaultPrng.init(seed);
    var random = seeds.random();
    var executed: usize = 0;
    for (0..cases) |case_index| {
        const case_seed = random.int(u64);
        var generator = std.Random.DefaultPrng.init(case_seed);
        const text = try generate(init.gpa, generator.random());
        defer init.gpa.free(text);

        const ran = exercise(init.gpa, text) catch |err| {
            std.debug.print(
                "fuzz failure: campaign seed {d}, case {d}, case seed {d}: {s}\n\n{s}\n",
                .{ seed, case_index, case_seed, @errorName(err), text },
            );
            return err;
        };
        executed += @intFromBool(ran);
    }

    std.debug.print("fuzz passed: seed {d}, {d} cases, {d} executed\n", .{ seed, cases, executed });
}

fn usage() noreturn {
    std.debug.print("usage: zig build fuzz -- [decimal seed] [case count]\n", .{});
    std.process.exit(64);
}

fn generate(gpa: std.mem.Allocator, random: std.Random) ![]const u8 {
    // Keep the malformed-token stream below for frontend recovery, but make a
    // regular fraction of inputs valid programs too. In particular, the
    // infinite-loop form proves the execution budget is exercised by the
    // campaign rather than only by its unit test.
    if (random.uintLessThan(u8, 8) == 0) {
        const count = random.uintLessThan(u8, 16);
        return switch (random.uintLessThan(u8, 5)) {
            0 => std.fmt.allocPrint(gpa,
                \\var i = 0
                \\while i < {d} {{
                \\    print(i)
                \\    i += 1
                \\}}
            , .{count}),
            1 => gpa.dupe(u8,
                \\while true {
                \\}
            ),
            2 => std.fmt.allocPrint(gpa,
                \\const values = [1, 2, 3, {d}]
                \\for value in values {{
                \\    print(value * 2)
                \\}}
            , .{count}),
            3 => std.fmt.allocPrint(gpa,
                \\class Outer {{
                \\    enum Mode {{
                \\        low, high
                \\    }}
                \\
                \\    struct Inner {{
                \\        var n: Int
                \\
                \\        func doubled(): Self {{
                \\            return Outer.Inner(self.n * 2)
                \\        }}
                \\
                \\        func Inner.make(n: Int): Outer.Inner {{
                \\            return Outer.Inner(n)
                \\        }}
                \\    }}
                \\}}
                \\
                \\const inner: Outer.Inner = Outer.Inner.make({d})
                \\const mode = if inner.n > 7 then Outer.Mode.high else Outer.Mode.low
                \\case mode {{
                \\    when Outer.Mode.low {{
                \\        print(inner.doubled())
                \\    }}
                \\    when Outer.Mode.high {{
                \\        print(mode)
                \\    }}
                \\}}
            , .{count}),
            else => std.fmt.allocPrint(gpa,
                \\const score = {d}
                \\const result = if score > 5 then score * 2 else if score == 0 then 1 else score
                \\print(result, (if score > 0 then 2 else 3) + 1)
            , .{count}),
        };
    }

    // Every atom is valid UTF-8. Concatenating them keeps each generated input
    // valid UTF-8 while allowing the lexer and parser to see malformed syntax,
    // comments, interpolation-looking text, punctuation, and Unicode.
    const atoms = [_][]const u8{
        "",           " ",        "\n",       "\t",   "a",  "Z",    "_",      "?",    "!",     "0",       "1",     "9",
        "\"",         "'",        "#",        "(",    ")",  "[",    "]",      "{",    "}",     ".",       ",",     ":",
        ";",          "+",        "-",        "*",    "/",  "=",    "<",      ">",    "&",     "|",       "\\",
        "é",
        "λ",
        "中",
        "😀",
        "\u{0301}",   "var",      "const",    "func", "if", "else", "return", "true", "false", "nothing", "print", "## note\n",
        "#[ note ]#", "\"text\"", "\"#{x}\"", "then",
    };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    const count = random.uintLessThan(usize, 129);
    for (0..count) |_| try text.appendSlice(gpa, atoms[random.uintLessThan(usize, atoms.len)]);
    return text.toOwnedSlice(gpa);
}

/// Returns whether this generated input reached the interpreter.
fn exercise(gpa: std.mem.Allocator, text: []const u8) !bool {
    var source = try emerald.Source.init(gpa, "fuzz.em", text);
    defer source.deinit(gpa);
    var tokenized = try emerald.Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    try requireBoundedDiagnostics(source.text, tokenized.diagnostics.len);

    var parsed = try emerald.Parser.parse(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    try requireBoundedDiagnostics(source.text, parsed.diagnostics.len);

    if (tokenized.diagnostics.len != 0 or parsed.diagnostics.len != 0) return false;

    // Syntactically valid input reaches the checker too, not only the
    // formatter: a crash here is exactly what frontend fuzzing exists to
    // catch, even though (unlike the lexer's and parser's) the checker's own
    // diagnostic count is not required to be zero or bounded here.
    var checked = try emerald.check(gpa, &source);
    defer checked.deinit();

    // Runtime errors are expected from arbitrary generated input. The point is
    // that execution itself, including all cleanup, cannot crash or hang. A
    // discarded writer keeps a bounded-step loop from turning into unbounded
    // captured output.
    const ran = checked.ok();
    if (ran) {
        var discard_buffer: [4096]u8 = undefined;
        var discarded: std.Io.Writer.Discarding = .init(&discard_buffer);
        var no_input: std.Io.Reader = .fixed("");
        var run_report = try emerald.runWithStepLimit(gpa, &source, .{ .out = &discarded.writer, .in = &no_input }, max_execution_steps);
        defer run_report.deinit();
    }

    const once = try emerald.Formatter.print(gpa, &source, tokenized.tokens, parsed.program, .stroustrup);
    defer gpa.free(once);
    var formatted_source = try emerald.Source.init(gpa, "formatted-fuzz.em", once);
    defer formatted_source.deinit(gpa);
    var formatted_tokens = try emerald.Lexer.tokenize(gpa, &formatted_source);
    defer formatted_tokens.deinit(gpa);
    if (formatted_tokens.diagnostics.len != 0) return error.FormatterProducedDiagnostics;
    var formatted_parsed = try emerald.Parser.parse(gpa, &formatted_source, formatted_tokens.tokens);
    defer formatted_parsed.deinit();
    if (formatted_parsed.diagnostics.len != 0) return error.FormatterProducedDiagnostics;

    const twice = try emerald.Formatter.print(gpa, &formatted_source, formatted_tokens.tokens, formatted_parsed.program, .stroustrup);
    defer gpa.free(twice);
    if (!std.mem.eql(u8, once, twice)) return error.FormatterIsNotIdempotent;
    return ran;
}

fn requireBoundedDiagnostics(text: []const u8, count: usize) !void {
    // At most one report per byte plus one final structural report. This is
    // intentionally generous, but catches runaway recovery loops.
    if (count > text.len + 1) return error.UnboundedDiagnostics;
}
