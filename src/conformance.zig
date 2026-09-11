//! Runs the conformance suite in `conformance/`.
//!
//! These cases are written in Emerald rather than Zig, and their expectations are
//! Emerald behavior rather than implementation structure. Section 19.6 requires
//! language semantics to be defined once in backend-neutral tests, and section
//! 23 requires an end-to-end behavioral test for anything a future backend could
//! inherit incorrectly from its host. A replacement backend is acceptable only
//! when it passes these same files unchanged.
//!
//! Two directories, distinguished by what they assert:
//!
//!   conformance/valid/        must produce no diagnostics
//!   conformance/diagnostics/  must produce exactly the text in its `.expected`
//!
//! To add a case, drop in a `.em` file. A case under `diagnostics/` also needs a
//! `.expected` file holding the exact rendered output; run the suite once to see
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

/// Renders every diagnostic a case produced, in order, exactly as the command
/// line would print them.
fn renderReport(gpa: std.mem.Allocator, source: Source, report: emerald.Report) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (report.diagnostics) |diagnostic| {
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
    const bytes = try root.readFileAlloc(io, case.relative_path, gpa, .limited(Source.max_bytes));
    defer gpa.free(bytes);

    // The display path is the relative one, so expectations stay machine-independent.
    var source = try Source.init(gpa, case.relative_path, bytes);
    defer source.deinit(gpa);

    var report = try emerald.check(gpa, &source);
    defer report.deinit(gpa);

    const actual = try renderReport(gpa, source, report);
    defer gpa.free(actual);

    if (std.mem.startsWith(u8, case.relative_path, "valid")) {
        if (report.ok()) return 0;
        std.debug.print(
            "\n{s}: expected no diagnostics, got:\n{s}",
            .{ case.relative_path, actual },
        );
        return 1;
    }

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
