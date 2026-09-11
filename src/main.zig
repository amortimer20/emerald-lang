//! The `emerald` command-line entry point.
//!
//! Section 18.1 defines the full command set. Only `check` exists so far: it
//! analyses a source file without running it. Commands join this file as the
//! stages behind them are built.

const std = @import("std");
const emerald = @import("emerald");

/// Section 18.1 fixes these, so they are named rather than written as bare numbers.
const ExitCode = enum(u8) {
    success = 0,
    source_diagnostics = 1,
    invalid_usage = 64,
};

const usage =
    \\usage: emerald check <file.em>
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3 or !std.mem.eql(u8, args[1], "check")) {
        try writeAll(io, .stderr, usage);
        return @intFromEnum(ExitCode.invalid_usage);
    }

    return check(gpa, io, args[2]);
}

fn check(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
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

    var report = try emerald.check(gpa, &source);
    defer report.deinit(gpa);

    if (!report.ok()) {
        for (report.diagnostics) |diagnostic| {
            const rendered = try diagnostic.renderAlloc(gpa, source);
            defer gpa.free(rendered);
            try writeAll(io, .stderr, rendered);
        }
        return @intFromEnum(ExitCode.source_diagnostics);
    }

    try writeAll(io, .stdout, "No problems found.\n");
    return @intFromEnum(ExitCode.success);
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    const file: std.Io.File = switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    };
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
