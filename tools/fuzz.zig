//! A bounded, deterministic frontend fuzz runner.
//!
//!     zig build fuzz -Doptimize=ReleaseSafe -- [seed] [cases]
//!
//! Inputs are always valid UTF-8 source text, but are intentionally not always
//! valid Emerald. Every input must lex and parse without crashing or producing
//! an unbounded diagnostic cascade. Inputs accepted by both stages also reach
//! the checker, which must not crash either, and are formatted twice;
//! formatting must keep them parseable and be idempotent. Execution is
//! deliberately not exercised here: the generator has no loop keywords today,
//! but a checked-but-unrun program cannot hang or produce unbounded output
//! even if that changes, which running one could.

const std = @import("std");
const emerald = @import("emerald");

const default_seed: u64 = 12_648_430;
const default_cases: usize = 1_000;

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
    for (0..cases) |case_index| {
        const case_seed = random.int(u64);
        var generator = std.Random.DefaultPrng.init(case_seed);
        const text = try generate(init.gpa, generator.random());
        defer init.gpa.free(text);

        exercise(init.gpa, text) catch |err| {
            std.debug.print(
                "fuzz failure: campaign seed {d}, case {d}, case seed {d}: {s}\n\n{s}\n",
                .{ seed, case_index, case_seed, @errorName(err), text },
            );
            return err;
        };
    }

    std.debug.print("fuzz passed: seed {d}, {d} cases\n", .{ seed, cases });
}

fn usage() noreturn {
    std.debug.print("usage: zig build fuzz -- [decimal seed] [case count]\n", .{});
    std.process.exit(64);
}

fn generate(gpa: std.mem.Allocator, random: std.Random) ![]const u8 {
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
        "#[ note ]#", "\"text\"", "\"#{x}\"",
    };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    const count = random.uintLessThan(usize, 129);
    for (0..count) |_| try text.appendSlice(gpa, atoms[random.uintLessThan(usize, atoms.len)]);
    return text.toOwnedSlice(gpa);
}

fn exercise(gpa: std.mem.Allocator, text: []const u8) !void {
    var source = try emerald.Source.init(gpa, "fuzz.em", text);
    defer source.deinit(gpa);
    var tokenized = try emerald.Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    try requireBoundedDiagnostics(source.text, tokenized.diagnostics.len);

    var parsed = try emerald.Parser.parse(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    try requireBoundedDiagnostics(source.text, parsed.diagnostics.len);

    if (tokenized.diagnostics.len != 0 or parsed.diagnostics.len != 0) return;

    // Syntactically valid input reaches the checker too, not only the
    // formatter: a crash here is exactly what frontend fuzzing exists to
    // catch, even though (unlike the lexer's and parser's) the checker's own
    // diagnostic count is not required to be zero or bounded here.
    var checked = try emerald.check(gpa, &source);
    defer checked.deinit();

    const once = try emerald.Formatter.print(gpa, &source, tokenized.tokens, parsed.program);
    defer gpa.free(once);
    var formatted_source = try emerald.Source.init(gpa, "formatted-fuzz.em", once);
    defer formatted_source.deinit(gpa);
    var formatted_tokens = try emerald.Lexer.tokenize(gpa, &formatted_source);
    defer formatted_tokens.deinit(gpa);
    if (formatted_tokens.diagnostics.len != 0) return error.FormatterProducedDiagnostics;
    var formatted_parsed = try emerald.Parser.parse(gpa, &formatted_source, formatted_tokens.tokens);
    defer formatted_parsed.deinit();
    if (formatted_parsed.diagnostics.len != 0) return error.FormatterProducedDiagnostics;

    const twice = try emerald.Formatter.print(gpa, &formatted_source, formatted_tokens.tokens, formatted_parsed.program);
    defer gpa.free(twice);
    if (!std.mem.eql(u8, once, twice)) return error.FormatterIsNotIdempotent;
}

fn requireBoundedDiagnostics(text: []const u8, count: usize) !void {
    // At most one report per byte plus one final structural report. This is
    // intentionally generous, but catches runaway recovery loops.
    if (count > text.len + 1) return error.UnboundedDiagnostics;
}
