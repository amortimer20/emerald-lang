//! `zig build test-compiler` (docs/compiler-design-plan.md, decision 11):
//! builds each case listed in `conformance/compiled.txt` with `emerald build`,
//! runs the executable, and holds it to the same `.expected` file the
//! interpreter is held to. A `run/` case must print exactly that, ending with
//! its `.status` when there is one; a `runtime-errors/` case must fail with
//! exactly that on standard error, and status 2.
//!
//! The list grows slice by slice, as the compiler learns the language, and is
//! deleted in slice 7, when it holds every case. Every case runs even after
//! one fails, so one run reports the whole picture.
//!
//! Usage: test_compiler <emerald> <zig> <build-tools> <conformance> <scratch>

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) {
        std.debug.print("usage: test_compiler <emerald> <zig> <build-tools> <conformance> <scratch>\n", .{});
        return 64;
    }
    // The cases are built and run from the conformance directory, so every
    // other path is made absolute first.
    const arena = init.arena.allocator();
    const here = try std.process.currentPathAlloc(io, arena);
    const emerald = try std.fs.path.resolve(arena, &.{ here, args[1] });
    const build_tools = try std.fs.path.resolve(arena, &.{ here, args[3] });
    const conformance = args[4];
    const scratch = try std.fs.path.resolve(arena, &.{ here, args[5] });

    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    // The build's own Zig, and the runtime library it just built, stand in
    // for the build tools a release ships.
    var inherited = init.environ_map.iterator();
    while (inherited.next()) |entry| try environment.put(entry.key_ptr.*, entry.value_ptr.*);
    try environment.put("EMERALD_ZIG", args[2]);
    try environment.put("EMERALD_BUILD_TOOLS", build_tools);

    const cwd = std.Io.Dir.cwd();
    var root = try cwd.openDir(io, conformance, .{});
    defer root.close(io);
    try cwd.createDirPath(io, scratch);

    const list = try root.readFileAlloc(io, "compiled.txt", gpa, .limited(1 << 20));
    defer gpa.free(list);

    var failures: usize = 0;
    var count: usize = 0;
    var previous: []const u8 = "";
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Sorted, so a case is added in one obvious place and never twice.
        if (std.mem.order(u8, previous, line) != .lt) {
            std.debug.print("compiled.txt: `{s}` is out of order or repeated\n", .{line});
            failures += 1;
        }
        previous = line;
        count += 1;
        if (!try runCase(gpa, io, root, emerald, scratch, &environment, line)) failures += 1;
    }

    if (failures != 0) {
        std.debug.print("\n{d} of {d} compiled cases failed.\n", .{ failures, count });
        return 1;
    }
    return 0;
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, emerald: []const u8, scratch: []const u8, environment: *const std.process.Environ.Map, case: []const u8) !bool {
    if (!std.mem.endsWith(u8, case, ".em")) {
        std.debug.print("compiled.txt: `{s}` is not a `.em` case\n", .{case});
        return false;
    }
    const stem = case[0 .. case.len - 3];
    const runtime_error = std.mem.startsWith(u8, case, "runtime-errors/");
    if (!runtime_error and !std.mem.startsWith(u8, case, "run/")) {
        std.debug.print("compiled.txt: `{s}` is not under run/ or runtime-errors/\n", .{case});
        return false;
    }

    var name_buffer: [256]u8 = undefined;
    const flat = std.mem.replaceOwned(u8, gpa, stem, "/", "-") catch return error.OutOfMemory;
    defer gpa.free(flat);
    const executable_name = try std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ flat, builtin.target.exeFileExt() });
    const executable = try std.fs.path.resolve(gpa, &.{ scratch, executable_name });
    defer gpa.free(executable);

    // Built from the conformance directory, so the paths in its messages are
    // the relative ones its expectations hold.
    const built = try run(gpa, io, &.{ emerald, "build", "-o", executable, case }, root, environment, null);
    defer built.deinit(gpa);
    if (!built.exitedWith(0)) {
        std.debug.print("\n{s}: `emerald build` failed:\n{s}{s}", .{ case, built.stdout, built.stderr });
        return false;
    }

    const input_path = try std.fmt.allocPrint(gpa, "{s}.input", .{stem});
    defer gpa.free(input_path);
    const input: ?std.Io.File = root.openFile(io, input_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (input) |file| file.close(io);

    const ran = try run(gpa, io, &.{executable}, root, environment, input);
    defer ran.deinit(gpa);

    const expected_path = try std.fmt.allocPrint(gpa, "{s}.expected", .{stem});
    defer gpa.free(expected_path);
    const expected = try root.readFileAlloc(io, expected_path, gpa, .limited(1 << 24));
    defer gpa.free(expected);

    if (runtime_error) {
        if (!ran.exitedWith(2)) {
            std.debug.print("\n{s}: expected status 2 for a runtime error, got {any}\n{s}", .{ case, ran.term, ran.stderr });
            return false;
        }
        return compare(case, expected, ran.stderr);
    }

    const status_path = try std.fmt.allocPrint(gpa, "{s}.status", .{stem});
    defer gpa.free(status_path);
    const want: u8 = if (root.readFileAlloc(io, status_path, gpa, .limited(16))) |text| blk: {
        defer gpa.free(text);
        break :blk try std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t\r\n"), 10);
    } else |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    if (!ran.exitedWith(want)) {
        std.debug.print("\n{s}: expected status {d}, got {any}\n{s}", .{ case, want, ran.term, ran.stderr });
        return false;
    }
    return compare(case, expected, ran.stdout);
}

fn compare(case: []const u8, expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    std.debug.print("\n{s}: compiled output differs.\n--- expected\n{s}\n--- actual\n{s}\n", .{ case, expected, actual });
    return false;
}

const Ran = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn exitedWith(self: Ran, code: u8) bool {
        return switch (self.term) {
            .exited => |status| status == code,
            else => false,
        };
    }

    fn deinit(self: Ran, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// `std.process.run`, with standard input from `input` when there is one.
fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.Io.Dir, environment: *const std.process.Environ.Map, input: ?std.Io.File) !Ran {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdin = if (input) |file| .{ .file = file } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}
