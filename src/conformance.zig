//! Runs the conformance suite in `conformance/`.
//!
//! These cases are written in Emerald rather than Zig, and their expectations are
//! Emerald behavior rather than implementation structure. Section 19.6 requires
//! language semantics to be defined once in backend-neutral tests, and section
//! 23 requires an end-to-end behavioral test for anything a future backend could
//! inherit incorrectly from its host. A replacement backend is acceptable only
//! when it passes these same files unchanged.
//!
//! The top directory of a case decides what is asserted:
//!
//!   conformance/lexical/         tokenizes with no diagnostics
//!   conformance/diagnostics/     `check` reports exactly its `.expected`
//!   conformance/run/             runs, and prints exactly its `.expected`
//!   conformance/runtime-errors/  runs, then fails with exactly its `.expected`
//!
//! `lexical/` exists because the lexer accepts far more of the language than the
//! parser does yet. Those cases hold real lexical rules that are worth protecting
//! now, and they graduate to `run/` as the stages behind them land.
//!
//! To add a case, drop in a `.em` file. Every directory except `lexical/` also
//! needs a `.expected` file holding the exact output; run the suite once to see
//! what the compiler produces, then read it carefully before saving it, because a
//! golden file that was never read only records what the compiler did, not what
//! it should do.

const std = @import("std");
const build_options = @import("build_options");

const emerald = @import("emerald");
const Source = emerald.Source;

const testing = std.testing;

/// A case's path relative to the conformance root, used both to find the file
/// and as the file name in expected diagnostics, so golden files do not embed
/// machine-specific absolute paths.
const Case = struct {
    relative_path: []const u8,

    fn lessThan(_: void, a: Case, b: Case) bool {
        return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
    }
};

fn collectCases(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |case| gpa.free(case.relative_path);
        cases.deinit(gpa);
    }

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".em")) continue;
        try cases.append(gpa, .{ .relative_path = try gpa.dupe(u8, entry.path) });
    }

    // Walk order is undefined, and section 16.3 wants deterministic ordering.
    std.mem.sort(Case, cases.items, {}, Case.lessThan);
    return cases.toOwnedSlice(gpa);
}

/// What a case asserts, taken from the directory it sits in.
const Kind = enum {
    lexical,
    diagnostics,
    run,
    runtime_errors,

    fn fromPath(relative_path: []const u8) ?Kind {
        const separator = std.mem.indexOfScalar(u8, relative_path, '/') orelse return null;
        const directory = relative_path[0..separator];
        if (std.mem.eql(u8, directory, "lexical")) return .lexical;
        if (std.mem.eql(u8, directory, "diagnostics")) return .diagnostics;
        if (std.mem.eql(u8, directory, "run")) return .run;
        if (std.mem.eql(u8, directory, "runtime-errors")) return .runtime_errors;
        return null;
    }
};

/// Renders diagnostics in order, exactly as the command line prints them.
fn renderDiagnostics(
    gpa: std.mem.Allocator,
    source: Source,
    diagnostics: []const emerald.Diagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (diagnostics) |diagnostic| {
        diagnostic.render(source, &out.writer) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

test "conformance suite" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root = try std.Io.Dir.cwd().openDir(io, build_options.conformance_dir, .{ .iterate = true });
    defer root.close(io);

    const cases = try collectCases(gpa, io, root);
    defer {
        for (cases) |case| gpa.free(case.relative_path);
        gpa.free(cases);
    }

    try testing.expect(cases.len > 0);

    var failures: usize = 0;
    for (cases) |case| {
        failures += try runCase(gpa, io, root, case);
    }

    if (failures != 0) {
        std.debug.print("\n{d} of {d} conformance cases failed\n", .{ failures, cases.len });
        return error.ConformanceFailed;
    }
}

/// Returns 1 when the case failed. Every case runs even after one fails, so a
/// single run reports the whole picture rather than only the first problem.
fn runCase(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, case: Case) !usize {
    const kind = Kind.fromPath(case.relative_path) orelse {
        std.debug.print(
            "\n{s}: not in a recognized directory. See conformance/README.md.\n",
            .{case.relative_path},
        );
        return 1;
    };

    const bytes = try root.readFileAlloc(io, case.relative_path, gpa, .limited(Source.max_bytes));
    defer gpa.free(bytes);

    // The display path is the relative one, so expectations stay machine-independent.
    var source = try Source.init(gpa, case.relative_path, bytes);
    defer source.deinit(gpa);

    // A case may give its program input to read, in a `.input` file beside it.
    const input_path = try std.fmt.allocPrint(gpa, "{s}.input", .{case.relative_path[0 .. case.relative_path.len - ".em".len]});
    defer gpa.free(input_path);
    const input = root.readFileAlloc(io, input_path, gpa, .limited(Source.max_bytes)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => |other| return other,
    };
    defer gpa.free(input);

    const actual = try produce(gpa, &source, kind, input) orelse return 1;
    defer gpa.free(actual);

    if (kind == .lexical) {
        if (actual.len == 0) return 0;
        std.debug.print(
            "\n{s}: expected no diagnostics, got:\n{s}",
            .{ case.relative_path, actual },
        );
        return 1;
    }

    return compareWithExpected(gpa, io, root, case, actual);
}

/// Produces the output a case is judged on, or null when the case failed in a
/// way that has already been reported.
fn produce(gpa: std.mem.Allocator, source: *const Source, kind: Kind, input: []const u8) !?[]u8 {
    switch (kind) {
        .lexical => {
            var tokenized = try emerald.Lexer.tokenize(gpa, source);
            defer tokenized.deinit(gpa);
            return try renderDiagnostics(gpa, source.*, tokenized.diagnostics);
        },
        .diagnostics => {
            var report = try emerald.check(gpa, source);
            defer report.deinit();
            return try renderDiagnostics(gpa, source.*, report.diagnostics);
        },
        .run, .runtime_errors => {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            var in: std.Io.Reader = .fixed(input);
            var report = try emerald.run(gpa, source, .{ .out = &out.writer, .in = &in });
            defer report.deinit();

            if (report.diagnostics.len != 0) {
                const rendered = try renderDiagnostics(gpa, source.*, report.diagnostics);
                defer gpa.free(rendered);
                std.debug.print(
                    "\n{s}: expected to run, but it did not check:\n{s}",
                    .{ source.path, rendered },
                );
                return null;
            }

            if (kind == .run) {
                if (report.failure) |failure| {
                    const rendered = try renderDiagnostics(gpa, source.*, &.{failure});
                    defer gpa.free(rendered);
                    std.debug.print(
                        "\n{s}: expected to run to completion, but it failed:\n{s}",
                        .{ source.path, rendered },
                    );
                    return null;
                }
                return try gpa.dupe(u8, out.written());
            }

            const failure = report.failure orelse {
                std.debug.print(
                    "\n{s}: expected a runtime error, but it ran to completion.\n",
                    .{source.path},
                );
                return null;
            };
            return try renderDiagnostics(gpa, source.*, &.{failure});
        },
    }
}

fn compareWithExpected(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    case: Case,
    actual: []const u8,
) !usize {
    const expected_path = try std.fmt.allocPrint(gpa, "{s}.expected", .{
        case.relative_path[0 .. case.relative_path.len - ".em".len],
    });
    defer gpa.free(expected_path);

    const expected = root.readFileAlloc(io, expected_path, gpa, .limited(Source.max_bytes)) catch {
        std.debug.print(
            "\n{s}: no {s}. The compiler produced:\n{s}",
            .{ case.relative_path, expected_path, actual },
        );
        return 1;
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) return 0;

    std.debug.print(
        "\n{s}: expected\n{s}\nbut got\n{s}",
        .{ case.relative_path, expected, actual },
    );
    return 1;
}
