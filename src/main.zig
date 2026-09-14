//! The `emerald` command-line entry point.
//!
//! Section 18.1 defines the full command set. `check` analyses a file without
//! executing it, and `run` checks it and then executes it. The rest of the
//! commands join this file as the stages behind them are built.

const std = @import("std");
const builtin = @import("builtin");
const emerald = @import("emerald");
const Repl = @import("Repl.zig");

/// Section 18.1 fixes these, so they are named rather than written as bare numbers.
const ExitCode = enum(u8) {
    success = 0,
    source_diagnostics = 1,
    runtime_error = 2,
    test_failures = 3,
    invalid_usage = 64,
    internal_failure = 70,
};

const usage =
    \\usage: emerald <command> <file.em>
    \\
    \\commands:
    \\  check           report problems without running the program
    \\  run             report problems, then run the program
    \\  test            report problems, then run every @test function
    \\  format          rewrite a file, or its project, in the canonical style
    \\  format --check  report which files would change, without writing them
    \\  repl            start an interactive session
    \\
;

const Command = enum { check, run, @"test", format, repl };

/// The allocator a program's runtime work goes through. Zig's default for a
/// ReleaseSafe build without libc is its leak-checking debug allocator, which
/// made a loop that declares a local 100 times slower than one that does not.
/// Leak checking stays in Debug builds, where the tests run.
fn runtimeAllocator(init: std.process.Init) std.mem.Allocator {
    return if (builtin.mode == .Debug) init.gpa else std.heap.smp_allocator;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = runtimeAllocator(init);
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return misuse(io);

    const command = std.meta.stringToEnum(Command, args[1]) orelse return misuse(io);

    if (command == .format) {
        // `emerald format [--check] <path>`: the one command with an
        // optional flag, so its argument count is checked on its own.
        if (args.len == 3) return executeFormat(gpa, io, args[2], false);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--check")) return executeFormat(gpa, io, args[3], true);
        return misuse(io);
    }

    if (command == .repl) {
        // Unlike every other command, `emerald repl` names no file (18.1).
        if (args.len != 2) return misuse(io);
        return executeRepl(gpa, io);
    }

    if (args.len != 3) return misuse(io);
    return execute(gpa, io, command, args[2]);
}

fn misuse(io: std.Io) !u8 {
    try writeAll(io, .stderr, usage);
    return @intFromEnum(ExitCode.invalid_usage);
}

fn execute(gpa: std.mem.Allocator, io: std.Io, command: Command, path: []const u8) !u8 {
    // Section 14.1: the file alone, unless it sits beside a `main.em`, in which
    // case the whole project comes with it.
    var project = emerald.Project.load(gpa, io, path) catch |err| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "emerald: cannot read '{s}': {t}\n", .{
            path,
            err,
        }) catch "emerald: cannot read the requested file\n";
        try writeAll(io, .stderr, message);
        return @intFromEnum(ExitCode.invalid_usage);
    };
    defer project.deinit(gpa);

    const sources = try project.sources(gpa);
    defer gpa.free(sources);

    // Program output is written straight through, so it interleaves with
    // anything the program itself prints in the order it happened.
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);

    const analysis = switch (command) {
        .check => emerald.checkProject(gpa, &project),
        .run => emerald.runProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface }),
        .@"test" => emerald.testProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface }),
        // `main` routes `format` and `repl` to their own functions before
        // this is reached.
        .format, .repl => unreachable,
    };
    var report = analysis catch |err| return internalFailure(io, err);
    defer report.deinit();

    try out.interface.flush();

    if (report.diagnostics.len != 0) {
        try writeDiagnostics(gpa, io, sources, report.diagnostics);
        return @intFromEnum(ExitCode.source_diagnostics);
    }

    if (report.failure) |failure| {
        try writeDiagnostics(gpa, io, sources, &.{failure});
        return @intFromEnum(ExitCode.runtime_error);
    }

    if (command == .@"test") {
        if (report.test_failures.len != 0) {
            try writeDiagnostics(gpa, io, sources, report.test_failures);
            var buffer: [128]u8 = undefined;
            const summary = if (report.test_count == 1)
                try std.fmt.bufPrint(&buffer, "1 test, {d} failed.\n", .{report.test_failures.len})
            else
                try std.fmt.bufPrint(&buffer, "{d} tests, {d} failed.\n", .{ report.test_count, report.test_failures.len });
            try writeAll(io, .stdout, summary);
            return @intFromEnum(ExitCode.test_failures);
        }
        var buffer: [128]u8 = undefined;
        const summary = if (report.test_count == 1)
            try std.fmt.bufPrint(&buffer, "1 test passed.\n", .{})
        else
            try std.fmt.bufPrint(&buffer, "{d} tests passed.\n", .{report.test_count});
        try writeAll(io, .stdout, summary);
    }

    if (command == .check) try writeAll(io, .stdout, "No problems found.\n");
    return @intFromEnum(ExitCode.success);
}

/// `emerald format` and `emerald format --check` (18.3). Formatting is
/// project-aware exactly like `check`/`run`: `path` names a lone file, or the
/// entry of whatever project it sits in, and every file of that project is
/// formatted. `check_only` reports which files would change, without writing
/// any of them, exiting `1` (section 18.1's status shared with source
/// diagnostics) when at least one would.
fn executeFormat(gpa: std.mem.Allocator, io: std.Io, path: []const u8, check_only: bool) !u8 {
    var project = emerald.Project.load(gpa, io, path) catch |err| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "emerald: cannot read '{s}': {t}\n", .{ path, err }) catch
            "emerald: cannot read the requested file\n";
        try writeAll(io, .stderr, message);
        return @intFromEnum(ExitCode.invalid_usage);
    };
    defer project.deinit(gpa);

    const sources = try project.sources(gpa);
    defer gpa.free(sources);

    var report = emerald.formatProject(gpa, &project) catch |err| return internalFailure(io, err);
    defer report.deinit();

    if (report.diagnostics.len != 0) {
        try writeDiagnostics(gpa, io, sources, report.diagnostics);
        return @intFromEnum(ExitCode.source_diagnostics);
    }

    var changed_any = false;
    for (project.files, report.files) |file, formatted| {
        if (!formatted.changed) continue;
        changed_any = true;
        if (check_only) continue;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file.source.path, .data = formatted.text }) catch |err| {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "emerald: cannot write '{s}': {t}\n", .{ file.source.path, err }) catch
                "emerald: cannot write the formatted file\n";
            try writeAll(io, .stderr, message);
            return @intFromEnum(ExitCode.internal_failure);
        };
    }

    if (check_only and changed_any) return @intFromEnum(ExitCode.source_diagnostics);
    return @intFromEnum(ExitCode.success);
}

/// A failure of Emerald itself rather than of the program, which section 18.1
/// keeps apart from source and runtime errors with its own status.
/// `emerald repl` (18.4). Both the REPL's own prompt-reading and any typed
/// code's `input()` calls read from this one shared, long-lived stdin
/// stream — see `Repl.run`'s doc comment.
fn executeRepl(gpa: std.mem.Allocator, io: std.Io) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);

    Repl.run(gpa, &in.interface, &out.interface) catch |err| switch (err) {
        error.OutOfMemory => return internalFailure(io, error.OutOfMemory),
        error.WriteFailed => return internalFailure(io, error.WriteFailed),
        error.ReadFailed => {
            try writeAll(io, .stderr, "emerald: could not read from the terminal\n");
            return @intFromEnum(ExitCode.internal_failure);
        },
        error.StackUnavailable => return internalFailure(io, error.StackUnavailable),
    };
    return @intFromEnum(ExitCode.success);
}

fn internalFailure(io: std.Io, err: emerald.Error) !u8 {
    const message = switch (err) {
        error.OutOfMemory => "emerald: ran out of memory\n",
        error.StackUnavailable => "emerald: could not reserve the stack it needs to run programs safely\n",
        error.WriteFailed => "emerald: could not write the program's output\n",
    };
    try writeAll(io, .stderr, message);
    return @intFromEnum(ExitCode.internal_failure);
}

fn writeDiagnostics(
    gpa: std.mem.Allocator,
    io: std.Io,
    sources: []const emerald.Source,
    diagnostics: []const emerald.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const rendered = try diagnostic.renderAlloc(gpa, sources);
        defer gpa.free(rendered);
        try writeAll(io, .stderr, rendered);
    }
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    const file: std.Io.File = switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    };
    // Streaming, not positional. A positional writer starts at offset 0, so a
    // second call would overwrite the first once the stream is redirected to a
    // file — which is exactly how the conformance suite reads our output.
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
