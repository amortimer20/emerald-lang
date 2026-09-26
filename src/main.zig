//! The `emerald` command-line entry point.
//!
//! Section 18.1 defines the full command set. `check` analyses a file without
//! executing it, and `run` checks it and then executes it. The rest of the
//! commands join this file as the stages behind them are built.

const std = @import("std");
const builtin = @import("builtin");
const emerald = @import("emerald");
const version_options = @import("version_options");
const Repl = @import("Repl.zig");
const Lsp = @import("Lsp.zig");
const ColorPolicy = emerald.ColorPolicy;
const TimeZone = emerald.TimeZone;

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
    \\  explain   learn about a diagnostic
    \\  help      show help for a command
    \\
    \\Run `emerald help <command>` for command-specific help.
    \\
;

const Command = enum { check, run, @"test", format, repl, lsp, explain, help };

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
    if (std.mem.eql(u8, args[1], "--version")) {
        if (args.len == 2) return printVersion(io);
        return commandMisuse(io, null, "`--version` must be used on its own");
    }
    if (std.mem.eql(u8, args[1], "--help")) {
        if (args.len == 2) return printGlobalHelp(io);
        return commandMisuse(io, null, "`--help` must be used on its own");
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse return unknownCommand(io, args[1]);

    if (command == .help) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) return printCommandHelp(io, command);
        return executeHelp(io, args[2..]);
    }
    if (command == .explain) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) return printCommandHelp(io, command);
        return executeExplain(io, args[2..]);
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
        return executeRepl(gpa, io, init.environ_map);
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
        return execute(gpa, io, command, args[2], &.{}, false, .utc);
    }

    // `run` and `test` accept an optional `--color=auto|always|never` flag
    // before the path (rewrite-context 15.6). `auto` and no flag at all mean
    // the same thing: fall through to the environment and the output
    // terminal, resolved below.
    var path_index: usize = 2;
    var color_flag: ?ColorPolicy.Flag = null;
    if (std.mem.startsWith(u8, args[path_index], "--color")) {
        const value = if (std.mem.indexOfScalar(u8, args[path_index], '=')) |at|
            args[path_index][at + 1 ..]
        else
            "";
        color_flag = std.meta.stringToEnum(ColorPolicy.Flag, value) orelse
            return commandMisuse(io, command, "expects `--color=auto`, `--color=always`, or `--color=never`");
        path_index += 1;
        if (path_index >= args.len) return commandMisuse(io, command, "expects a `<file.em>` path");
    }

    // Section 14.1: `--` separates Emerald's own arguments from the running
    // program's. `run` and `test` hand these to a program as
    // `Program.arguments`.
    var program_arguments: []const []const u8 = &.{};
    if (args.len > path_index + 1) {
        if (!std.mem.eql(u8, args[path_index + 1], "--")) return commandMisuse(io, command, "expects program arguments after `--`");
        program_arguments = args[path_index + 2 ..];
    }
    const color = try resolveColor(io, init.environ_map, color_flag);
    var zone_arena: std.heap.ArenaAllocator = .init(gpa);
    defer zone_arena.deinit();
    const local_zone = resolveLocalZone(zone_arena.allocator(), io, init.environ_map);
    return execute(gpa, io, command, args[path_index], program_arguments, color, local_zone);
}

/// Section 15.8's `TimeZone.local` for one invocation, allocated in `arena`.
/// Whatever cannot be read or understood leaves the program in UTC, as glibc
/// does, rather than stopping it.
fn resolveLocalZone(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) TimeZone.Local {
    if (builtin.os.tag == .windows) return windowsZone(arena);
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link = if (std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &link_buffer)) |length| link_buffer[0..length] else |_| null;
    switch (TimeZone.localSource(environ_map.get("TZ"), link)) {
        .utc => return .utc,
        .file => |file| {
            const rules = readZoneFile(arena, io, file.path) orelse return .utc;
            return .{ .name = arena.dupe(u8, file.name) catch return .utc, .rules = rules };
        },
        .named => |name| {
            for (TimeZone.zoneinfo_directories) |directory| {
                const path = std.mem.concat(arena, u8, &.{ directory, name }) catch return .utc;
                if (readZoneFile(arena, io, path)) |rules| return .{ .name = name, .rules = rules };
            }
            const rule = TimeZone.parsePosix(name) orelse return .utc;
            return .{ .name = name, .rules = .{ .initial = rule.standard, .footer = rule } };
        },
    }
}

fn readZoneFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?TimeZone.Rules {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    return TimeZone.parseTzif(arena, bytes) catch null;
}

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

const DYNAMIC_TIME_ZONE_INFORMATION = extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: SYSTEMTIME,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: SYSTEMTIME,
    DaylightBias: i32,
    TimeZoneKeyName: [128]u16,
    DynamicDaylightTimeDisabled: u8,
};

extern "kernel32" fn GetDynamicTimeZoneInformation(information: *DYNAMIC_TIME_ZONE_INFORMATION) callconv(.winapi) u32;

/// Windows describes the machine's zone by its key name, such as `Eastern
/// Standard Time`, and this year's rule for changing clocks.
fn windowsZone(arena: std.mem.Allocator) TimeZone.Local {
    var information: DYNAMIC_TIME_ZONE_INFORMATION = undefined;
    if (GetDynamicTimeZoneInformation(&information) == 0xFFFF_FFFF) return .utc;
    const key_utf16 = std.mem.sliceTo(&information.TimeZoneKeyName, 0);
    const key = if (key_utf16.len == 0) "Local" else std.unicode.utf16LeToUtf8Alloc(arena, key_utf16) catch return .utc;
    // Known as its IANA name, so the built-in database's full history is used
    // for it; Windows's own current rule stays as the fallback.
    const name = TimeZone.windowsZoneName(key) orelse key;
    const date = struct {
        fn of(time: SYSTEMTIME) TimeZone.WindowsDate {
            return .{ .year = time.wYear, .month = time.wMonth, .weekday = time.wDayOfWeek, .week = time.wDay, .hour = time.wHour, .minute = time.wMinute };
        }
    };
    var daylight = date.of(information.DaylightDate);
    if (information.DynamicDaylightTimeDisabled != 0) daylight.month = 0;
    const rule = TimeZone.fromWindows(information.Bias, information.StandardBias, information.DaylightBias, date.of(information.StandardDate), daylight);
    return .{ .name = name, .rules = .{ .initial = rule.standard, .footer = rule } };
}

/// Resolves rewrite-context 15.6's color precedence against the real
/// process for one invocation: `flag` is whatever `--color` parsed to (`run`
/// and `test`) or `null` (`repl`, which has no flag of its own).
/// `ColorPolicy.resolve` itself is a pure function with its own unit tests;
/// this just gathers what it needs from the environment and stdout.
///
/// On Windows, a real console may need one-time setup: a legacy console does
/// not process ANSI escapes until asked to. Forced output never configures a
/// console, so it remains usable for files, pipes, and CI logs. If automatic
/// Windows setup fails, automatic styling is simply unavailable for that run.
fn resolveColor(io: std.Io, environ_map: *const std.process.Environ.Map, flag: ?ColorPolicy.Flag) !bool {
    const stdout = std.Io.File.stdout();
    // A failed terminal probe must not stop a program. It simply means auto
    // mode cannot establish a terminal that can render its ANSI strings.
    const is_tty = stdout.isTty(io) catch false;
    // On Windows, an ordinary console can render ANSI only after
    // `enableAnsiEscapeCodes` turns VT processing on. Its current support
    // answer is therefore not a reason to reject an otherwise real TTY.
    const supports_ansi = if (builtin.os.tag == .windows and is_tty)
        true
    else
        stdout.supportsAnsiEscapeCodes(io) catch false;
    const no_color = environ_map.get("NO_COLOR");
    const force_color = environ_map.get("FORCE_COLOR");
    const color = ColorPolicy.resolve(.{
        .flag = flag,
        .no_color = no_color,
        .force_color = force_color,
        .term = environ_map.get("TERM"),
        .is_tty = is_tty,
        .supports_ansi = supports_ansi,
    });
    const force_active = if (force_color) |value|
        value.len != 0 and !std.mem.eql(u8, value, "0")
    else
        false;
    const no_color_active = if (no_color) |value| value.len != 0 else false;
    const auto = (flag == null or flag.? == .auto) and !force_active and !no_color_active;
    // Only auto detection configures a Windows console. `always` and
    // FORCE_COLOR intentionally also work for redirected output, where there
    // is no console to configure and a downstream reader owns interpretation.
    if (color and auto and is_tty and builtin.os.tag == .windows) {
        stdout.enableAnsiEscapeCodes(io) catch return false;
    }
    return color;
}

fn printGlobalHelp(io: std.Io) !u8 {
    try writeAll(io, .stdout, global_help);
    return @intFromEnum(ExitCode.success);
}

fn printVersion(io: std.Io) !u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "Emerald {s}\n", .{version_options.version}) catch "Emerald\n";
    try writeAll(io, .stdout, text);
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
        \\Usage: emerald run [--color=auto|always|never] <file.em> [-- <program-argument>...]
        \\
        \\Check a file or project, then run it. Arguments after `--` become
        \\Program.arguments. `--color` controls Console's ANSI styling and
        \\defaults to `auto`, which styles output only on a terminal that
        \\supports it; NO_COLOR and FORCE_COLOR are also honored.
        \\
        ,
        .@"test" =>
        \\Usage: emerald test [--color=auto|always|never] <file.em> [-- <program-argument>...]
        \\
        \\Check a file or project, then run every @test function. Arguments
        \\after `--` become Program.arguments. `--color` controls Console's
        \\ANSI styling the same way `run`'s does.
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
        .explain =>
        \\Usage: emerald explain <diagnostic-code>
        \\
        \\Show a worked explanation for a diagnostic code, such as E1001.
        \\Codes appear in square brackets in explained CLI diagnostics.
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

fn executeExplain(io: std.Io, arguments: []const []const u8) !u8 {
    if (arguments.len != 1) return commandMisuse(io, .explain, "expects a diagnostic code such as E1001");
    const code = emerald.Diagnostic.Code.fromText(arguments[0]) orelse return unknownExplanation(io, arguments[0]);
    const explanation = code.explanation();
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "{s}: {s}\n\nProblem:\n{s}\nTry this:\n{s}",
        .{ code.text(), explanation.title, explanation.example, explanation.correction },
    ) catch "Emerald could not prepare this explanation.\n";
    try writeAll(io, .stdout, text);
    return @intFromEnum(ExitCode.success);
}

fn unknownExplanation(io: std.Io, code: []const u8) !u8 {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "emerald: `{s}` is not an explained diagnostic code\nTry `emerald help explain` to see how explained codes work.\n",
        .{code},
    ) catch "emerald: this is not an explained diagnostic code\nRun `emerald help explain` for usage.\n";
    try writeAll(io, .stderr, message);
    return @intFromEnum(ExitCode.invalid_usage);
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

fn execute(gpa: std.mem.Allocator, io: std.Io, command: Command, path: []const u8, program_arguments: []const []const u8, color: bool, local_zone: TimeZone.Local) !u8 {
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
        .run => emerald.runProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface, .color = color, .local_zone = local_zone, .arguments = program_arguments }),
        .@"test" => emerald.testProject(gpa, &project, .{ .out = &out.interface, .in = &in.interface, .color = color, .local_zone = local_zone, .arguments = program_arguments }),
        // `main` routes `format`, `repl`, `lsp`, and `help` to their own functions
        // before this is reached.
        .format, .repl, .lsp, .explain, .help => unreachable,
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
fn executeRepl(gpa: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);

    // Decision 5: the REPL resolves the policy the same way `run` does, with
    // no `--color` flag of its own to override it.
    const color = try resolveColor(io, environ_map, null);
    var zone_arena: std.heap.ArenaAllocator = .init(gpa);
    defer zone_arena.deinit();
    const local_zone = resolveLocalZone(zone_arena.allocator(), io, environ_map);

    Repl.run(gpa, &in.interface, &out.interface, color, local_zone) catch |err| switch (err) {
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
        var rendered: std.Io.Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        try diagnostic.renderWithCode(sources, &rendered.writer, true);
        try writeAll(io, .stderr, rendered.written());
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
