//! `emerald build` (docs/compiler-design-plan.md): a checked program, lowered
//! to the IR, emitted as C, and compiled by the Zig toolchain in Emerald's
//! build tools against the runtime library built for the target.

const std = @import("std");
const builtin = @import("builtin");
const emerald = @import("../emerald.zig");
const Source = @import("../Source.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Lower = @import("Lower.zig");
const EmitC = @import("EmitC.zig");

/// The runtime's C interface, written beside the generated C.
pub const header = @embedFile("../runtime/emerald.h");

pub const Generated = union(enum) {
    /// The C was written.
    c,
    /// The program is valid, but uses something the compiler cannot compile
    /// yet. The diagnostic says what; its `message` is the caller's to free.
    unsupported: Diagnostic,
};

/// Writes the C for `project`, which has checked without errors, to `out`.
/// Analysis needs the large stack every recursive stage uses, and lowering
/// and emitting walk the same trees, so all three run there.
pub fn generate(gpa: std.mem.Allocator, project: *const emerald.Project, out: *std.Io.Writer) !Generated {
    const Task = struct {
        gpa: std.mem.Allocator,
        project: *const emerald.Project,
        out: *std.Io.Writer,
        result: anyerror!Generated = undefined,

        fn go(task: *@This(), available: usize) void {
            _ = available;
            task.result = generateHere(task.gpa, task.project, task.out);
        }
    };
    var task: Task = .{ .gpa = gpa, .project = project, .out = out };
    const thread = emerald.Scheduler.ReservedThread.spawn(emerald.stack_size, Task.go, .{ &task, emerald.stack_size }) catch
        return error.StackUnavailable;
    thread.join();
    return task.result;
}

fn generateHere(gpa: std.mem.Allocator, project: *const emerald.Project, out: *std.Io.Writer) !Generated {
    var analysis = (try emerald.analyzeProjectOnThisStack(gpa, project)) orelse return error.NotChecked;
    defer analysis.deinit(gpa);
    if (!analysis.ok()) return error.NotChecked;

    const entry = project.entry;
    const source = &analysis.files[entry].source;
    if (project.files.len != 1) return .{ .unsupported = try unsupported(gpa, entry, .{ .start = 0, .end = 0 }, "a project of several files") };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var lower: Lower = .{
        .arena = arena_state.allocator(),
        .source = source,
        .file = @intCast(entry),
        .checked = &analysis.checked,
        .facts = &analysis.resolved.facts,
    };
    const program = lower.lower(analysis.programs[entry]) catch |err| switch (err) {
        error.Unsupported => return .{ .unsupported = try unsupported(gpa, entry, lower.unsupported.?.span, lower.unsupported.?.what) },
        error.OutOfMemory => return error.OutOfMemory,
    };
    try EmitC.emit(gpa, program, source, out);
    return .c;
}

/// The caller frees the diagnostic's `message` with `gpa`.
fn unsupported(gpa: std.mem.Allocator, file: u32, span: Source.Span, what: []const u8) !Diagnostic {
    return .{
        .file = file,
        .span = span,
        .message = try std.fmt.allocPrint(gpa, "`emerald build` cannot compile {s} yet", .{what}),
        .help = "Run the program with `emerald run` instead. The compiler learns more of the language with each release.",
    };
}

/// Where the build tools are: the Zig toolchain, and the runtime library for
/// the target.
pub const Tools = struct {
    zig: []const u8,
    runtime_library: []const u8,
};

/// What `findTools` could not find, as a message for the person building.
pub const Missing = struct { message: []const u8 };

/// The target the runtime library is named for, `arch-os-abi`, as `zig build`
/// installs it (build.zig).
pub fn hostTriple() []const u8 {
    return @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);
}

const runtime_library_name = if (builtin.os.tag == .windows) "emerald_runtime.lib" else "libemerald_runtime.a";
const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// Looks for the build tools: in `EMERALD_BUILD_TOOLS` when it is set, else
/// in `build-tools` beside the executable or beside its directory, as the
/// release archives will place them (decision 2). `EMERALD_ZIG` names a Zig
/// executable to use instead of the tools' own, which is how Emerald's own
/// tests build with the Zig that builds Emerald.
pub fn findTools(arena: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) !union(enum) { found: Tools, missing: Missing } {
    var candidates: std.ArrayList([]const u8) = .empty;
    if (environment.get("EMERALD_BUILD_TOOLS")) |directory| {
        try candidates.append(arena, directory);
    } else if (std.process.executableDirPathAlloc(io, arena)) |executable_dir| {
        try candidates.append(arena, try std.fs.path.join(arena, &.{ executable_dir, "build-tools" }));
        try candidates.append(arena, try std.fs.path.join(arena, &.{ executable_dir, "..", "build-tools" }));
    } else |_| {}

    const cwd = std.Io.Dir.cwd();
    for (candidates.items) |directory| {
        const library = try std.fs.path.join(arena, &.{ directory, "runtime", hostTriple(), runtime_library_name });
        cwd.access(io, library, .{}) catch continue;
        const zig = environment.get("EMERALD_ZIG") orelse try std.fs.path.join(arena, &.{ directory, "zig", zig_name });
        cwd.access(io, zig, .{}) catch return .{ .missing = .{ .message = try std.fmt.allocPrint(arena,
            \\emerald: build needs Emerald's build tools, and their Zig toolchain is missing from '{s}'.
            \\Unpack the build tools for this system there again, or set EMERALD_ZIG to a Zig executable.
            \\
        , .{directory}) } };
        return .{ .found = .{ .zig = zig, .runtime_library = library } };
    }
    return .{ .missing = .{ .message = try std.fmt.allocPrint(arena,
        \\emerald: build needs Emerald's build tools, which hold the C compiler it uses and the runtime
        \\for {s}, and they are not installed.
        \\Unpack the build tools archive for this system into a folder named `build-tools` beside
        \\emerald, or set EMERALD_BUILD_TOOLS to the folder you unpacked it into.
        \\
    , .{hostTriple()}) } };
}

pub const Options = struct {
    /// Keep runtime assertions and full debug information (decision 10);
    /// otherwise an optimized build, which still keeps every language check.
    debug: bool = false,
};

/// Compiles `c_path`, which includes `emerald.h` from `include_dir`, into
/// `output`. Gives null on success, or what the toolchain printed when it
/// failed, which is Emerald's fault rather than the program's.
pub fn compileC(gpa: std.mem.Allocator, io: std.Io, tools: Tools, c_path: []const u8, include_dir: []const u8, output: []const u8, options: Options) !?[]u8 {
    const include = try std.fmt.allocPrint(gpa, "-I{s}", .{include_dir});
    defer gpa.free(include);
    const output_flag = try std.fmt.allocPrint(gpa, "-o{s}", .{output});
    defer gpa.free(output_flag);
    const argv: []const []const u8 = &.{
        tools.zig,                         "cc",
        "-std=c11",                        if (options.debug) "-O0" else "-O2",
        // Stripped unless debugging, which also keeps Windows from writing a
        // `.pdb` beside every executable.
        if (options.debug) "-g" else "-s",
        // The C is generated, so its warnings are Emerald's to fix, not the
        // programmer's to read.
        "-w",
        include,                           c_path,
        tools.runtime_library,             output_flag,
    };
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (succeeded) {
        gpa.free(result.stderr);
        return null;
    }
    return result.stderr;
}
