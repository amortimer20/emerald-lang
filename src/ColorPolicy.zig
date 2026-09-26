//! Console styling's color policy (rewrite-context 15.6):
//! whether an execution emits ANSI SGR sequences at all, resolved from the
//! `--color` flag, `NO_COLOR`/`FORCE_COLOR`/`TERM`, and whether the output is
//! a terminal that supports ANSI escapes. `resolve` is a pure function of
//! its inputs so every precedence case has a unit test without a real
//! terminal or a real environment; `main.zig` gathers the real inputs (the
//! parsed flag, the environment, and `std.Io.File.isTty`/
//! `supportsAnsiEscapeCodes` against actual stdout) and calls it once per
//! `run`/`test`/`repl` invocation.

const std = @import("std");

/// The three `--color` values `run`/`test` accept (18.1's command set).
/// `auto` and no flag at all mean the same thing: fall through to the
/// environment and the terminal.
pub const Flag = enum { auto, always, never };

/// Everything the precedence reads, gathered here so `resolve` stays pure.
pub const Inputs = struct {
    flag: ?Flag = null,
    no_color: ?[]const u8 = null,
    force_color: ?[]const u8 = null,
    term: ?[]const u8 = null,
    is_tty: bool = false,
    supports_ansi: bool = false,
};

/// Rewrite-context 15.6's precedence, highest first:
///
/// 1. `--color=always`/`--color=never` (an explicit `flag` other than
///    `.auto`) settles it outright.
/// 2. `NO_COLOR` present and non-empty turns styling off, per no-color.org,
///    which says a CLI argument overrides it — already handled by 1.
/// 3. `FORCE_COLOR` present, non-empty, and not `"0"` turns styling on.
/// 4. `TERM=dumb` turns styling off.
/// 5. Otherwise, on only when the output is a TTY that supports ANSI.
///
/// If both `NO_COLOR` and `FORCE_COLOR` are set, `NO_COLOR` wins as the
/// safer reading.
pub fn resolve(inputs: Inputs) bool {
    if (inputs.flag) |flag| switch (flag) {
        .always => return true,
        .never => return false,
        .auto => {},
    };
    if (inputs.no_color) |value| {
        if (value.len != 0) return false;
    }
    if (inputs.force_color) |value| {
        if (value.len != 0 and !std.mem.eql(u8, value, "0")) return true;
    }
    if (inputs.term) |value| {
        if (std.mem.eql(u8, value, "dumb")) return false;
    }
    return inputs.is_tty and inputs.supports_ansi;
}

const testing = std.testing;

test "no flag, no environment, no tty: off" {
    try testing.expect(!resolve(.{}));
}

test "a supporting tty turns styling on with no flag or environment" {
    try testing.expect(resolve(.{ .is_tty = true, .supports_ansi = true }));
}

test "a tty that does not support ansi stays off" {
    try testing.expect(!resolve(.{ .is_tty = true, .supports_ansi = false }));
}

test "--color=always overrides everything, even a dumb terminal" {
    try testing.expect(resolve(.{ .flag = .always, .term = "dumb" }));
}

test "--color=never overrides NO_COLOR and FORCE_COLOR forcing on" {
    try testing.expect(!resolve(.{
        .flag = .never,
        .force_color = "1",
        .is_tty = true,
        .supports_ansi = true,
    }));
}

test "--color=auto is the same as no flag at all" {
    try testing.expect(resolve(.{ .flag = .auto, .is_tty = true, .supports_ansi = true }));
    try testing.expect(!resolve(.{ .flag = .auto }));
}

test "NO_COLOR wins over FORCE_COLOR when both are set" {
    try testing.expect(!resolve(.{ .no_color = "1", .force_color = "1" }));
}

test "an empty NO_COLOR does not count as present" {
    try testing.expect(resolve(.{ .no_color = "", .is_tty = true, .supports_ansi = true }));
}

test "FORCE_COLOR turns styling on even for redirected output" {
    try testing.expect(resolve(.{ .force_color = "1" }));
}

test "FORCE_COLOR=0 does not force color on" {
    try testing.expect(!resolve(.{ .force_color = "0" }));
}

test "an empty FORCE_COLOR does not force color on" {
    try testing.expect(!resolve(.{ .force_color = "" }));
}

test "TERM=dumb turns styling off even on a supporting tty" {
    try testing.expect(!resolve(.{ .term = "dumb", .is_tty = true, .supports_ansi = true }));
}

test "TERM=dumb does not override FORCE_COLOR, which is checked first" {
    try testing.expect(resolve(.{ .term = "dumb", .force_color = "1" }));
}
