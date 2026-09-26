//! Checks Emerald's JSON parser against Nicolas Seriot's JSONTestSuite,
//! whose files name whether a strict parser must accept or reject them
//! (README.md, `test_parsing/`): `y_` must parse, `n_` must be refused, and
//! `i_` may go either way, since real parsers disagree on those (huge
//! numbers, a byte-order mark, and the like).
//!
//! Two `y_` files are a deliberate, documented exception: JSONTestSuite
//! counts a duplicate key as something a parser may accept (most do, the
//! last value winning), but docs/json-design-plan.md refuses one instead,
//! since in a file edited by hand it is almost always a mistake that would
//! otherwise silently discard data.
//!
//!     bash tools/json/fetch.sh .jsontestsuite
//!     zig build json-conformance -Doptimize=ReleaseSafe -- .jsontestsuite/test_parsing

const std = @import("std");
const Json = @import("emerald").Json;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: json-conformance <test_parsing directory>\n", .{});
        std.process.exit(64);
    }
    const cwd = std.Io.Dir.cwd();
    var directory = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer directory.close(io);

    // Emerald refuses a duplicate key on purpose (see the file's own doc
    // comment), so these two `y_` cases are expected to be refused rather
    // than a real mismatch.
    const known_exceptions = [_][]const u8{
        "y_object_duplicated_key.json",
        "y_object_duplicated_key_and_value.json",
    };

    var accepted: usize = 0;
    var rejected: usize = 0;
    var mismatches: usize = 0;
    var implementation_defined: usize = 0;
    var exceptions: usize = 0;

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const category = entry.name[0];
        if (category != 'y' and category != 'n' and category != 'i') continue;

        const text = try directory.readFileAlloc(io, entry.name, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(text);

        var problem: Json.Problem = .{};
        var document: ?Json.Document = Json.parse(gpa, text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => null,
        };
        defer if (document) |*doc| doc.deinit();
        const parsed = document != null;

        var expected_ok = category == 'y';
        for (known_exceptions) |name| {
            if (std.mem.eql(u8, entry.name, name)) {
                expected_ok = false;
                exceptions += 1;
            }
        }

        switch (category) {
            'y' => {
                accepted += 1;
                if (parsed != expected_ok) {
                    mismatches += 1;
                    std.debug.print("{s} should have parsed: line {d}, column {d}: {s}\n", .{ entry.name, problem.line, problem.column, problem.message() });
                }
            },
            'n' => {
                rejected += 1;
                if (parsed) {
                    mismatches += 1;
                    std.debug.print("{s} should have been refused, but parsed\n", .{entry.name});
                }
            },
            else => implementation_defined += 1,
        }
    }

    std.debug.print(
        "{d} accepted, {d} refused, {d} implementation-defined, {d} known exceptions, {d} mismatches\n",
        .{ accepted, rejected, implementation_defined, exceptions, mismatches },
    );
    if (mismatches > 0) std.process.exit(1);
}
