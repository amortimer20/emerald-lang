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
//!   conformance/color/           runs with Console styling forced on
//!   conformance/http/            runs against Emerald's local HTTP test server
//!   conformance/local-zone/      runs with `TimeZone.local` set to `EST5EDT`
//!   conformance/runtime-errors/  runs, then fails with exactly its `.expected`
//!
//! A case is usually one `.em` file. A directory holding a `main.em` is one
//! case too — a whole project, per section 14.1 — and its `.expected` sits
//! beside the directory rather than inside it.
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
const Repl = @import("repl");
const Source = emerald.Source;

const testing = std.testing;

/// A case's path relative to the conformance root, used both to find the file
/// and as the file name in expected diagnostics, so golden files do not embed
/// machine-specific absolute paths.
const Case = struct {
    /// The `.em` file, or the directory of a project case.
    relative_path: []const u8,
    /// The entry passed to the compiler: the file itself, or the project's
    /// `main.em`.
    entry_path: []const u8,
    /// Where `.expected` and `.input` sit, which is the case path without a
    /// `.em` suffix.
    stem: []const u8,

    fn lessThan(_: void, a: Case, b: Case) bool {
        return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
    }

    fn deinit(self: Case, gpa: std.mem.Allocator) void {
        gpa.free(self.relative_path);
        gpa.free(self.entry_path);
        gpa.free(self.stem);
    }
};

fn collectCases(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |case| case.deinit(gpa);
        cases.deinit(gpa);
    }

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const is_repl = std.mem.startsWith(u8, entry.path, "repl/") or std.mem.startsWith(u8, entry.path, "repl\\");
        const suffix: []const u8 = if (is_repl) ".input" else ".em";
        if (!std.mem.endsWith(u8, entry.path, suffix)) continue;

        const path = try gpa.dupe(u8, entry.path);
        defer gpa.free(path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');

        // A file inside a project is not a case of its own: the project is,
        // and its `main.em` is what registers it.
        if (projectRootOf(io, root, path)) |project| {
            if (!std.mem.eql(u8, std.fs.path.dirnamePosix(path) orelse "", project)) continue;
            if (!std.mem.eql(u8, std.fs.path.basenamePosix(path), "main.em")) continue;
            try cases.append(gpa, .{
                .relative_path = try gpa.dupe(u8, project),
                .entry_path = try gpa.dupe(u8, path),
                .stem = try gpa.dupe(u8, project),
            });
            continue;
        }

        try cases.append(gpa, .{
            .relative_path = try gpa.dupe(u8, path),
            .entry_path = try gpa.dupe(u8, path),
            .stem = try gpa.dupe(u8, path[0 .. path.len - suffix.len]),
        });
    }

    // Walk order is undefined, and section 16.3 wants deterministic ordering.
    std.mem.sort(Case, cases.items, {}, Case.lessThan);
    return cases.toOwnedSlice(gpa);
}

/// The nearest directory at or above the file that holds a `main.em`, or null
/// when the file is a program on its own.
fn projectRootOf(io: std.Io, root: std.Io.Dir, path: []const u8) ?[]const u8 {
    var at: []const u8 = std.fs.path.dirnamePosix(path) orelse return null;
    while (true) {
        if (isProjectRoot(io, root, at)) return at;
        at = std.fs.path.dirnamePosix(at) orelse return null;
    }
}

fn isProjectRoot(io: std.Io, root: std.Io.Dir, directory: []const u8) bool {
    if (directory.len == 0) return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = std.fmt.bufPrint(&buffer, "{s}/main.em", .{directory}) catch return false;
    root.access(io, candidate, .{}) catch return false;
    return true;
}

/// What a case asserts, taken from the directory it sits in.
const Kind = enum {
    lexical,
    diagnostics,
    run,
    color,
    http,
    local_zone,
    runtime_errors,
    format,
    repl,

    fn fromPath(relative_path: []const u8) ?Kind {
        const separator = std.mem.indexOfScalar(u8, relative_path, '/') orelse return null;
        const directory = relative_path[0..separator];
        if (std.mem.eql(u8, directory, "lexical")) return .lexical;
        if (std.mem.eql(u8, directory, "diagnostics")) return .diagnostics;
        if (std.mem.eql(u8, directory, "run")) return .run;
        if (std.mem.eql(u8, directory, "color")) return .color;
        if (std.mem.eql(u8, directory, "http")) return .http;
        if (std.mem.eql(u8, directory, "local-zone")) return .local_zone;
        if (std.mem.eql(u8, directory, "runtime-errors")) return .runtime_errors;
        if (std.mem.eql(u8, directory, "format")) return .format;
        if (std.mem.eql(u8, directory, "repl")) return .repl;
        return null;
    }
};

/// `local-zone/`'s machine zone: the United States' Eastern rules since
/// 2007, which make every change of clocks reproducible wherever the suite
/// runs. `EST5EDT` is also the IANA name of a zone with exactly these rules.
const eastern: emerald.TimeZone.Local = .{
    .name = "EST5EDT",
    .rules = .{
        .initial = -5 * 3600,
        .footer = emerald.TimeZone.parsePosix("EST5EDT,M3.2.0,M11.1.0").?,
    },
};

/// Renders diagnostics in order, exactly as the command line prints them.
fn renderDiagnostics(
    gpa: std.mem.Allocator,
    sources: []const Source,
    diagnostics: []const emerald.Diagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (diagnostics) |diagnostic| {
        diagnostic.render(sources, &out.writer) catch return error.OutOfMemory;
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
        for (cases) |case| case.deinit(gpa);
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

// Section 3.4 starts `else`, `catch`, and `finally` on their own lines, in
// both brace styles. The formatter writes them that way, but most conformance
// cases are never formatted, because many exercise layouts the formatter would
// change on purpose. This keeps the convention wherever a reader learns from
// Emerald code: runnable cases, examples, and the documentation's `emerald`
// blocks.
test "else, catch, and finally start their own lines" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Place = struct { path: []const u8, extension: []const u8 };
    const places = [_]Place{
        .{ .path = build_options.conformance_dir, .extension = ".em" },
        .{ .path = build_options.examples_dir, .extension = ".em" },
        .{ .path = build_options.docs_dir, .extension = ".md" },
    };

    var problems: usize = 0;
    for (places) |place| {
        var dir = try std.Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, place.extension)) continue;
            // These hold malformed or unformatted input on purpose.
            if (place.path.ptr == build_options.conformance_dir.ptr and deliberatelyUnformatted(entry.path)) continue;
            const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(Source.max_bytes));
            defer gpa.free(text);
            problems += sameLineContinuations(place.path, entry.path, text, std.mem.eql(u8, place.extension, ".md"));
        }
    }
    if (problems != 0) {
        std.debug.print("\n{d} `}} else`, `}} catch`, or `}} finally` lines; start each keyword on its own line (3.4)\n", .{problems});
        return error.StyleFailed;
    }
}

/// `diagnostics/`, `lexical/`, and `format/` cases are inputs, not models.
fn deliberatelyUnformatted(path: []const u8) bool {
    const end = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
    const top = path[0..end];
    return std.mem.eql(u8, top, "diagnostics") or std.mem.eql(u8, top, "lexical") or std.mem.eql(u8, top, "format");
}

/// Counts, and prints, lines that continue a closing brace with `else`,
/// `catch`, or `finally`. In Markdown only `emerald` code blocks are read.
fn sameLineContinuations(place: []const u8, path: []const u8, text: []const u8, markdown: bool) usize {
    var count: usize = 0;
    var in_emerald = !markdown;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (markdown and std.mem.startsWith(u8, line, "```")) {
            in_emerald = !in_emerald and std.mem.eql(u8, std.mem.trim(u8, line[3..], " "), "emerald");
            continue;
        }
        if (!in_emerald or !std.mem.startsWith(u8, line, "}")) continue;
        const rest = std.mem.trimStart(u8, line[1..], " \t");
        for ([_][]const u8{ "else", "catch", "finally" }) |keyword| {
            if (!std.mem.startsWith(u8, rest, keyword)) continue;
            const after = rest[keyword.len..];
            if (after.len != 0 and after[0] != ' ' and after[0] != '{') continue;
            // An inline `if`'s `else` may follow a block that ends its
            // `then` value: `} else "skipped"` is canonical.
            const next = std.mem.trimStart(u8, after, " ");
            if (std.mem.eql(u8, keyword, "else") and next.len != 0 and next[0] != '{' and !std.mem.startsWith(u8, next, "if ")) continue;
            std.debug.print("\n{s}/{s}:{d}: {s}", .{ place, path, number, line });
            count += 1;
        }
    }
    return count;
}

// Even deliberately non-canonical source must remain valid after formatting.
// Walk individual files so project members receive the same protection.
test "formatted run programs still parse" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var root = try std.Io.Dir.cwd().openDir(io, build_options.conformance_dir, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "run", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var problems: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".em")) continue;
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(Source.max_bytes));
        defer gpa.free(text);
        var source = try Source.init(gpa, entry.path, text);
        defer source.deinit(gpa);
        var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
        const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
        var report = try emerald.formatProject(gpa, &project);
        defer report.deinit();
        if (report.diagnostics.len != 0) {
            std.debug.print("\nrun/{s}: could not format the original program\n", .{entry.path});
            problems += 1;
            continue;
        }
        var formatted = try Source.init(gpa, entry.path, report.files[0].text);
        defer formatted.deinit(gpa);
        var formatted_files = [_]emerald.Project.File{.{ .source = formatted, .namespace = "", .entry = true }};
        const formatted_project: emerald.Project = .{ .files = &formatted_files, .entry = 0, .bad_directories = &.{} };
        // Reuse the frontend's large-stack path rather than parsing a deep
        // regression program on the test runner's host-chosen stack.
        var reparsed = try emerald.formatProject(gpa, &formatted_project);
        defer reparsed.deinit();
        if (!reparsed.ok()) {
            std.debug.print("\nrun/{s}: formatted output does not parse:\n{s}\n", .{ entry.path, formatted.text });
            problems += 1;
        }
    }
    if (problems != 0) return error.FormattedRunDidNotParse;
}

// Examples are what a reader copies, so each must already be exactly as the
// formatter writes it.
test "examples are formatted" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, build_options.examples_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var problems: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".em")) continue;
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(Source.max_bytes));
        defer gpa.free(text);
        var source = try Source.init(gpa, entry.path, text);
        defer source.deinit(gpa);
        var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
        const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
        var report = try emerald.formatProject(gpa, &project);
        defer report.deinit();
        if (report.diagnostics.len != 0 or !std.mem.eql(u8, report.files[0].text, text)) {
            std.debug.print("\nexamples/{s}: not formatted; run `emerald format` on it\n", .{entry.path});
            problems += 1;
        }
    }
    if (problems != 0) return error.StyleFailed;
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

    if (kind == .repl) {
        const input = try root.readFileAlloc(io, case.entry_path, gpa, .limited(Source.max_bytes));
        defer gpa.free(input);
        // Each transcript must be identical on 50 consecutive executions,
        // including on CI's real platform schedulers. Never retry a mismatch.
        for (0..50) |_| {
            var reader: std.Io.Reader = .fixed(input);
            var output: std.Io.Writer.Allocating = .init(gpa);
            defer output.deinit();
            if (try Repl.run(gpa, &reader, &output.writer, false, .empty, .utc, .{}) != 0) return 1;
            if (try compareWithExpected(gpa, io, root, case, output.written()) != 0) return 1;
        }
        return 0;
    }

    // The display paths are the relative ones, so expectations stay
    // machine-independent. A project case loads every file beside its entry.
    var project = try emerald.Project.loadIn(gpa, io, root, case.entry_path);
    defer project.deinit(gpa);

    const sources = try project.sources(gpa);
    defer gpa.free(sources);

    // A case may give its program input to read, in a `.input` file beside it.
    const input_path = try std.fmt.allocPrint(gpa, "{s}.input", .{case.stem});
    defer gpa.free(input_path);
    const input = root.readFileAlloc(io, input_path, gpa, .limited(Source.max_bytes)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => |other| return other,
    };
    defer gpa.free(input);

    var http_server: ?*emerald.Http.TestServer = null;
    var http_base: ?[]u8 = null;
    if (kind == .http) {
        http_server = try emerald.Http.TestServer.start(gpa);
        http_base = try http_server.?.url(gpa, "");
    }
    defer if (http_base) |base| gpa.free(base);
    defer if (http_server) |server| server.deinit();

    const actual = try produce(gpa, &project, sources, kind, input, if (http_base) |base| &.{base} else &.{}) orelse return 1;
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
fn produce(
    gpa: std.mem.Allocator,
    project: *const emerald.Project,
    sources: []const Source,
    kind: Kind,
    input: []const u8,
    arguments: []const []const u8,
) !?[]u8 {
    const entry = &project.files[project.entry].source;
    switch (kind) {
        .repl => unreachable, // transcript cases bypass project loading
        .lexical => {
            var tokenized = try emerald.Lexer.tokenize(gpa, entry);
            defer tokenized.deinit(gpa);
            return try renderDiagnostics(gpa, sources, tokenized.diagnostics);
        },
        .diagnostics => {
            var report = try emerald.checkProject(gpa, project);
            defer report.deinit();
            return try renderDiagnostics(gpa, sources, report.diagnostics);
        },
        .run, .color, .http, .local_zone, .runtime_errors => {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            var in: std.Io.Reader = .fixed(input);
            var report = try emerald.runProject(gpa, project, .{
                .out = &out.writer,
                .in = &in,
                .color = kind == .color,
                .local_zone = if (kind == .local_zone) eastern else .utc,
                .arguments = arguments,
            });
            defer report.deinit();

            // A warning (Diagnostic.Severity) does not stop checking or
            // execution, so it may sit alongside a normal run; this category
            // asserts the program's own printed output, which `diagnostics/`
            // already exists to check warning and error text against, so a
            // warning here is not itself a failure.
            if (emerald.Diagnostic.anyErrors(report.diagnostics)) {
                const rendered = try renderDiagnostics(gpa, sources, report.diagnostics);
                defer gpa.free(rendered);
                std.debug.print(
                    "\n{s}: expected to run, but it did not check:\n{s}",
                    .{ entry.path, rendered },
                );
                return null;
            }

            if (kind == .run or kind == .color or kind == .http or kind == .local_zone) {
                if (report.failure) |failure| {
                    const rendered = try renderDiagnostics(gpa, sources, &.{failure});
                    defer gpa.free(rendered);
                    std.debug.print(
                        "\n{s}: expected to run to completion, but it failed:\n{s}",
                        .{ entry.path, rendered },
                    );
                    return null;
                }
                return try gpa.dupe(u8, out.written());
            }

            const failure = report.failure orelse {
                std.debug.print(
                    "\n{s}: expected a runtime error, but it ran to completion.\n",
                    .{entry.path},
                );
                return null;
            };
            return try renderDiagnostics(gpa, sources, &.{failure});
        },
        .format => {
            var report = try emerald.formatProject(gpa, project);
            defer report.deinit();

            if (report.diagnostics.len != 0) {
                const rendered = try renderDiagnostics(gpa, sources, report.diagnostics);
                defer gpa.free(rendered);
                std.debug.print(
                    "\n{s}: expected to format cleanly, but it did not parse:\n{s}",
                    .{ entry.path, rendered },
                );
                return null;
            }

            const formatted = report.files[project.entry].text;

            // The formatter's central guarantee, checked on every case for
            // free: formatting its own output is a no-op.
            var reformatted_source = try Source.init(gpa, entry.path, formatted);
            defer reformatted_source.deinit(gpa);
            var reformatted_files = [_]emerald.Project.File{.{ .source = reformatted_source, .namespace = "", .entry = true }};
            const reformatted_project: emerald.Project = .{ .files = &reformatted_files, .entry = 0, .bad_directories = &.{} };
            var second_report = try emerald.formatProject(gpa, &reformatted_project);
            defer second_report.deinit();
            if (second_report.diagnostics.len != 0 or !std.mem.eql(u8, second_report.files[0].text, formatted)) {
                std.debug.print(
                    "\n{s}: formatting its own output changed it further, which should never happen:\n{s}",
                    .{ entry.path, formatted },
                );
                return null;
            }

            return try gpa.dupe(u8, formatted);
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
    const expected_path = try std.fmt.allocPrint(gpa, "{s}.expected", .{case.stem});
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
