//! The `emerald` command-line entry point.
//!
//! Section 18.1 defines the full command set. `check` analyses a file without
//! executing it, and `run` checks it and then executes it. The rest of the
//! commands join this file as the stages behind them are built.

const std = @import("std");
const builtin = @import("builtin");
const emerald = @import("emerald");
const Repl = @import("Repl.zig");
const Lsp = @import("Lsp.zig");

/// Section 18.1 fixes these, so they are named rather than written as bare numbers.
/// `invalid_usage` and `missing_input` both borrow their values from BSD's
/// `sysexits.h` (`EX_USAGE`/`EX_NOINPUT`), matching `internal_failure`'s own
/// `EX_SOFTWARE`: a command typed wrong and a file that cannot be read are
/// different problems for a caller to act on (fix the invocation, or check
/// the path), so they keep the distinct codes the standard already gives
/// them rather than sharing one.
const ExitCode = enum(u8) {
    success = 0,
    source_diagnostics = 1,
    runtime_error = 2,
    test_failures = 3,
    invalid_usage = 64,
    missing_input = 66,
    internal_failure = 70,
};

const global_help =
    \\Emerald
    \\
    \\Usage: emerald <command> [arguments]
    \\
    \\Commands:
    \\  run       run a program
    \\  check     report problems without running it
    \\  test      run tests
    \\  format    format a file or project
    \\  repl      start an interactive session
    \\  help      show help for a command
    \\
    \\Run `emerald help <command>` for command-specific help.
    \\
;

const Command = enum { check, run, @"test", format, repl, lsp, help };

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
    if (args.len < 2) return printGlobalHelp(io);
    if (std.mem.eql(u8, args[1], "--help")) {
        if (args.len == 2) return printGlobalHelp(io);
        return commandMisuse(io, null, "`--help` must be used on its own");
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse return unknownCommand(io, args[1]);

    if (command == .help) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) return printCommandHelp(io, command);
        return executeHelp(io, args[2..]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) return printCommandHelp(io, command);

    if (command == .format) {
        // `emerald format [--check] <path>`: the one command with an
        // optional flag, so its argument count is checked on its own.
        if (args.len == 3) return executeFormat(gpa, io, args[2], false);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--check")) return executeFormat(gpa, io, args[3], true);
        return commandMisuse(io, command, "expects `<file.em>` or `--check <file.em>`");
    }

    if (command == .repl) {
        // Unlike every other command, `emerald repl` names no file (18.1).
        if (args.len != 2) return commandMisuse(io, command, "does not take arguments");
        return executeRepl(gpa, io);
    }

    if (command == .lsp) {
        // Like `repl`, `emerald lsp` names no file: it serves whatever
        // documents the editor opens over stdio (18.5). stdio is the only
        // transport this implements, but an optional trailing `--stdio` is
        // still accepted and ignored: LSP clients (`vscode-languageclient`
        // included) that support multiple transports conventionally pass it
        // to select this one explicitly, even when a server offers no other.
        if (args.len == 2) return executeLsp(gpa, io);
        if (args.len == 3 and std.mem.eql(u8, args[2], "--stdio")) return executeLsp(gpa, io);
        return commandMisuse(io, command, "accepts only an optional `--stdio`");
    }

    if (args.len < 3) return commandMisuse(io, command, "expects a `<file.em>` path");
    if (command == .check) {
        if (args.len != 3) return commandMisuse(io, command, "does not run a program, so it cannot take program arguments");
        return execute(gpa, io, command, args[2], &.{});
    }

    // Section 14.1: `--` separates Emerald's own arguments from the running
    // program's. `run` and `test` hand these to a program as
    // `Program.arguments`.
    var program_arguments: []const []const u8 = &.{};
    if (args.len > 3) {
        if (!std.mem.eql(u8, args[3], "--")) return commandMisuse(io, command, "expects program arguments after `--`");
        program_arguments = args[4..];
    }
    return execute(gpa, io, command, args[2], program_arguments);
}

fn printGlobalHelp(io: std.Io) !u8 {
    try writeAll(io, .stdout, global_help);
    return @intFromEnum(ExitCode.success);
}

fn executeHelp(io: std.Io, topics: []const []const u8) !u8 {
    if (topics.len == 0) return printGlobalHelp(io);
    if (topics.len != 1) return commandMisuse(io, .help, "accepts at most one command name");
    const command = std.meta.stringToEnum(Command, topics[0]) orelse return unknownCommand(io, topics[0]);
    return printCommandHelp(io, command);
}

fn printCommandHelp(io: std.Io, command: Command) !u8 {
    const text = switch (command) {
        .check =>
        \\Usage: emerald check <file.em>
        \\
        \\Analyze a file or project without running Emerald code.
        \\
        ,
        .run =>
        \\Usage: emerald run <file.em> [-- <program-argument>...]
        \\
        \\Check a file or project, then run it. Arguments after `--` become
        \\Program.arguments.
        \\
        ,
        .@"test" =>
        \\Usage: emerald test <file.em> [-- <program-argument>...]
        \\
        \\Check a file or project, then run every @test function. Arguments
        \\after `--` become Program.arguments.
        \\
        ,
        .format =>
        \\Usage: emerald format <file.em>
        \\       emerald format --check <file.em>
        \\
        \\Format every file in the named file's project. `--check` lists files
        \\that would change without writing them.
        \\
        ,
        .repl =>
        \\Usage: emerald repl
        \\
        \\Start an interactive Emerald session. Use :help inside the REPL to
        \\see its commands.
        \\
        ,
        .lsp =>
        \\Usage: emerald lsp [--stdio]
        \\
        \\Start Emerald's language server over standard input and output for
        \\editor integration.
        \\
        ,
        .help =>
        \\Usage: emerald help [command]
        \\
        \\Show global help or detailed help for one command.
        \\
        ,
    };
    try writeAll(io, .stdout, text);
    return @intFromEnum(ExitCode.success);
}

fn unknownCommand(io: std.Io, name: []const u8) !u8 {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "emerald: unknown command `{s}`\nRun `emerald help` to see available commands.\n", .{name}) catch
        "emerald: unknown command\nRun `emerald help` to see available commands.\n";
    try writeAll(io, .stderr, message);
    return @intFromEnum(ExitCode.invalid_usage);
}

fn commandMisuse(io: std.Io, command: ?Command, detail: []const u8) !u8 {
    var buffer: [512]u8 = undefined;
    const message = if (command) |value|
        std.fmt.bufPrint(&buffer, "emerald: {s} {s}\nRun `emerald help {s}` for usage.\n", .{ @tagName(value), detail, @tagName(value) }) catch
            "emerald: invalid command usage\nRun `emerald help` to see available commands.\n"
    else
        std.fmt.bufPrint(&buffer, "emerald: {s}\nRun `emerald help` to see available commands.\n", .{detail}) catch
            "emerald: invalid command usage\nRun `emerald help` to see available commands.\n";
    try writeAll(io, .stderr, message);
    return @intFromEnum(ExitCode.invalid_usage);
}

fn execute(gpa: std.mem.Allocator, io: std.Io, command: Command, path: []const u8, program_arguments: []const []const u8) !u8 {
    // Section 14.1: the file alone, unless it sits beside a `main.em`, in which
    // case the whole project comes with it.
    var project = emerald.Project.load(gpa, io, path) catch |err| {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "emerald: cannot read '{s}': {t}\n", .{
            path,
            err,
        }) catch "emerald: cannot read the requested file\n";
        try writeAll(io, .stderr, message);
        return @intFromEnum(ExitCode.missing_input);
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
        .run => emerald.runProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface, .arguments = program_arguments }),
        .@"test" => emerald.testProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface, .arguments = program_arguments }),
        // `main` routes `format`, `repl`, `lsp`, and `help` to their own functions
        // before this is reached.
        .format, .repl, .lsp, .help => unreachable,
    };
    var report = analysis catch |err| return internalFailure(io, err);
    defer report.deinit();

    try out.interface.flush();

    // A warning (Diagnostic.Severity) does not stop checking or execution,
    // unlike an error, so it may sit alongside a normal, complete run: print
    // it, but keep going rather than returning immediately. `warned` remembers
    // to still report status 1 (18.1's status for "diagnostics") once nothing
    // more specific (a runtime failure, a test failure) took priority.
    var warned = false;
    if (report.diagnostics.len != 0) {
        try writeDiagnostics(gpa, io, sources, report.diagnostics);
        if (emerald.Diagnostic.anyErrors(report.diagnostics)) return @intFromEnum(ExitCode.source_diagnostics);
        warned = true;
    }

    if (report.failure) |failure| {
        try writeDiagnostics(gpa, io, sources, &.{failure});
        return @intFromEnum(ExitCode.runtime_error);
    }

    if (report.exit_code) |code| return code;

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

    if (warned) return @intFromEnum(ExitCode.source_diagnostics);
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
        return @intFromEnum(ExitCode.missing_input);
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

    var changed_count: usize = 0;
    for (project.files, report.files) |file, formatted| {
        if (!formatted.changed) continue;
        changed_count += 1;
        if (check_only) {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Would format {s}\n", .{file.source.path}) catch
                "Would format a file\n";
            try writeAll(io, .stdout, message);
            continue;
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file.source.path, .data = formatted.text }) catch |err| {
            var buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "emerald: cannot write '{s}': {t}\n", .{ file.source.path, err }) catch
                "emerald: cannot write the formatted file\n";
            try writeAll(io, .stderr, message);
            return @intFromEnum(ExitCode.internal_failure);
        };
    }

    if (check_only and changed_count != 0) {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Run `emerald format {s}` to apply these changes.\n", .{path}) catch
            "Run `emerald format <file.em>` to apply these changes.\n";
        try writeAll(io, .stdout, message);
        return @intFromEnum(ExitCode.source_diagnostics);
    }
    if (!check_only and changed_count != 0) {
        var buffer: [128]u8 = undefined;
        const message = if (changed_count == 1)
            std.fmt.bufPrint(&buffer, "Formatted 1 file.\n", .{}) catch "Formatted a file.\n"
        else
            std.fmt.bufPrint(&buffer, "Formatted {d} files.\n", .{changed_count}) catch "Formatted files.\n";
        try writeAll(io, .stdout, message);
    }
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

/// `emerald lsp` (18.5). Owns stdin/stdout for the JSON-RPC protocol itself,
/// the same way `executeRepl` owns them for its own line-based one.
fn executeLsp(gpa: std.mem.Allocator, io: std.Io) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);

    Lsp.run(gpa, io, &in.interface, &out.interface) catch |err| switch (err) {
        error.OutOfMemory => return internalFailure(io, error.OutOfMemory),
        error.WriteFailed => return internalFailure(io, error.WriteFailed),
        error.ReadFailed => {
            try writeAll(io, .stderr, "emerald: could not read from the client\n");
            return @intFromEnum(ExitCode.internal_failure);
        },
        error.MissingContentLength => {
            try writeAll(io, .stderr, "emerald: the client's message was not framed correctly\n");
            return @intFromEnum(ExitCode.internal_failure);
        },
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
