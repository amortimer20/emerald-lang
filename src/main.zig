//! The `emerald` command-line entry point.
//!
//! Section 18.1 defines the full command set. `check` analyses a file without
//! executing it, and `run` checks it and then executes it. The rest of the
//! commands join this file as the stages behind them are built.

const std = @import("std");
const emerald = @import("emerald");

/// Section 18.1 fixes these, so they are named rather than written as bare numbers.
const ExitCode = enum(u8) {
    success = 0,
    source_diagnostics = 1,
    runtime_error = 2,
    invalid_usage = 64,
    internal_failure = 70,
};

const usage =
    \\usage: emerald <command> <file.em>
    \\
    \\commands:
    \\  check   report problems without running the program
    \\  run     report problems, then run the program
    \\
;

const Command = enum { check, run };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return misuse(io);

    const command = std.meta.stringToEnum(Command, args[1]) orelse return misuse(io);
    return execute(gpa, io, command, args[2]);
}

fn misuse(io: std.Io) !u8 {
    try writeAll(io, .stderr, usage);
    return @intFromEnum(ExitCode.invalid_usage);
}

fn execute(gpa: std.mem.Allocator, io: std.Io, command: Command, path: []const u8) !u8 {
    var source = emerald.Source.load(gpa, io, path) catch |err| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "emerald: cannot read '{s}': {t}\n", .{
            path,
            err,
        }) catch "emerald: cannot read the requested file\n";
        try writeAll(io, .stderr, message);
        return @intFromEnum(ExitCode.invalid_usage);
    };
    defer source.deinit(gpa);

    // Program output is written straight through, so it interleaves with
    // anything the program itself prints in the order it happened.
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);

    const analysis = switch (command) {
        .check => emerald.check(gpa, &source),
        .run => emerald.run(gpa, &source, &out.interface),
    };
    var report = analysis catch |err| return internalFailure(io, err);
    defer report.deinit();

    try out.interface.flush();

    if (report.diagnostics.len != 0) {
        try writeDiagnostics(gpa, io, source, report.diagnostics);
        return @intFromEnum(ExitCode.source_diagnostics);
    }

    if (report.failure) |failure| {
        try writeDiagnostics(gpa, io, source, &.{failure});
        return @intFromEnum(ExitCode.runtime_error);
    }

    if (command == .check) try writeAll(io, .stdout, "No problems found.\n");
    return @intFromEnum(ExitCode.success);
}

/// A failure of Emerald itself rather than of the program, which section 18.1
/// keeps apart from source and runtime errors with its own status.
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
    source: emerald.Source,
    diagnostics: []const emerald.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const rendered = try diagnostic.renderAlloc(gpa, source);
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
