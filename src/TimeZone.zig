//! Section 15.8's time-zone rules: how far ahead of UTC a zone's clocks are at
//! a moment. A zone is a list of transitions, read from a TZif file (RFC 8536),
//! followed by a POSIX TZ rule that covers every moment after the last one.
//! A POSIX rule alone, as the `TZ` variable or Windows supplies, is a zone with
//! no transitions.
//!
//! The Emerald side (`TimeZone` in prelude.em) asks one question of these
//! rules: the offset at a moment. It resolves wall-clock times that a change
//! of clocks repeats or skips itself, from offsets on either side.
//!
//! `localSource` decides where the machine's own zone comes from as a pure
//! function of the environment, so every case has a unit test; `main.zig`
//! does the reading.

const std = @import("std");
const tzdata = @import("tzdata/tzdata.zig");

/// The IANA release built into Emerald (`tools/update-tzdata.py`).
pub const database_version = tzdata.version;

/// A moment, in seconds since 1970-01-01T00:00:00Z, from which clocks in the
/// zone are `offset` seconds ahead of UTC.
pub const Transition = struct {
    at: i64,
    offset: i32,
};

/// A POSIX TZ rule such as `EST5EDT,M3.2.0,M11.1.0`, with offsets stored the
/// way Emerald counts them: seconds east of UTC.
pub const Posix = struct {
    standard: i32,
    daylight: ?Daylight = null,

    pub const Daylight = struct {
        offset: i32,
        /// When daylight time starts, in local standard time.
        start: Change,
        /// When it ends, in local daylight time.
        end: Change,
    };

    /// A day of the year and a time on it. The time may be negative or past
    /// 24 hours (RFC 8536 section 3.3.1).
    pub const Change = struct {
        date: Date,
        time: i32 = 2 * 3600,
    };

    pub const Date = union(enum) {
        /// `Mm.w.d`: weekday `d` (0 is Sunday) of week `w` of month `m`, where
        /// week 5 means the last one.
        month_week_day: struct { month: u8, week: u8, weekday: u8 },
        /// `Jn`: day 1 through 365, never counting February 29.
        julian: u16,
        /// `n`: day 0 through 365, counting February 29 in a leap year.
        zero_based: u16,
    };

    pub fn offsetAt(self: Posix, at: i64) i32 {
        const daylight = self.daylight orelse return self.standard;
        const year = civilFromDays(@divFloor(at + self.standard, std.time.s_per_day)).year;
        const start = localSeconds(year, daylight.start) - self.standard;
        const end = localSeconds(year, daylight.end) - daylight.offset;
        const in_daylight = if (start < end)
            start <= at and at < end
        else
            // The southern hemisphere: daylight time spans the new year.
            !(end <= at and at < start);
        return if (in_daylight) daylight.offset else self.standard;
    }
};

pub const Rules = struct {
    /// The offset before the first transition.
    initial: i32,
    transitions: []const Transition = &.{},
    /// Covers every moment after the last transition, or all of them when
    /// there are none.
    footer: ?Posix = null,

    pub fn offsetAt(self: Rules, at: i64) i32 {
        const transitions = self.transitions;
        if (transitions.len == 0) return if (self.footer) |footer| footer.offsetAt(at) else self.initial;
        if (at < transitions[0].at) return self.initial;
        // The last transition at or before `at`.
        var low: usize = 0;
        var high: usize = transitions.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (transitions[middle].at <= at) low = middle else high = middle;
        }
        if (low == transitions.len - 1) if (self.footer) |footer| return footer.offsetAt(at);
        return transitions[low].offset;
    }

    pub fn deinit(self: Rules, gpa: std.mem.Allocator) void {
        gpa.free(self.transitions);
    }
};

/// The zone a running program calls `TimeZone.local`. UTC unless the host
/// resolves the machine's own, so tests and embedded runs are deterministic.
pub const Local = struct {
    name: []const u8 = "UTC",
    /// Null for UTC, whose offset the Emerald side knows without asking.
    rules: ?Rules = null,

    pub const utc: Local = .{};
};

pub fn parseTzif(gpa: std.mem.Allocator, bytes: []const u8) !Rules {
    var reader: std.Io.Reader = .fixed(bytes);
    var tz = try std.Tz.parse(gpa, &reader);
    defer tz.deinit();

    // RFC 8536: moments before the first transition use the first time type.
    const initial = tz.timetypes[0].offset;
    const transitions = try gpa.alloc(Transition, tz.transitions.len);
    errdefer gpa.free(transitions);
    for (tz.transitions, transitions) |from, *to| to.* = .{ .at = from.ts, .offset = from.timetype.offset };
    const footer = if (tz.footer) |text| parsePosix(text) else null;
    return .{ .initial = initial, .transitions = transitions, .footer = footer };
}

/// Reads a POSIX TZ rule, or returns null when `text` is not one. A zone name
/// with daylight time but no dates for it uses the United States' rules, as
/// glibc does.
pub fn parsePosix(text: []const u8) ?Posix {
    var parser: PosixParser = .{ .text = text };
    return parser.parse();
}

const PosixParser = struct {
    text: []const u8,
    at: usize = 0,

    fn parse(self: *PosixParser) ?Posix {
        if (!self.name()) return null;
        const standard = -(self.duration(24) orelse return null);
        if (self.done()) return .{ .standard = standard };
        if (!self.name()) return null;
        var daylight_offset = standard + 3600;
        if (!self.done() and self.peek() != ',') daylight_offset = -(self.duration(24) orelse return null);
        const default_start: Posix.Change = .{ .date = .{ .month_week_day = .{ .month = 3, .week = 2, .weekday = 0 } } };
        const default_end: Posix.Change = .{ .date = .{ .month_week_day = .{ .month = 11, .week = 1, .weekday = 0 } } };
        if (self.done()) return .{ .standard = standard, .daylight = .{ .offset = daylight_offset, .start = default_start, .end = default_end } };
        if (!self.take(',')) return null;
        const start = self.change() orelse return null;
        if (!self.take(',')) return null;
        const end = self.change() orelse return null;
        if (!self.done()) return null;
        return .{ .standard = standard, .daylight = .{ .offset = daylight_offset, .start = start, .end = end } };
    }

    fn done(self: *const PosixParser) bool {
        return self.at == self.text.len;
    }

    fn peek(self: *const PosixParser) u8 {
        return self.text[self.at];
    }

    fn take(self: *PosixParser, byte: u8) bool {
        if (self.done() or self.peek() != byte) return false;
        self.at += 1;
        return true;
    }

    /// `EST`, or `<+0530>` for a name that is not only letters. At least three
    /// characters either way.
    fn name(self: *PosixParser) bool {
        const start = self.at;
        if (self.take('<')) {
            while (!self.done() and self.peek() != '>') self.at += 1;
            if (!self.take('>')) return false;
            return self.at - start - 2 >= 3;
        }
        while (!self.done() and std.ascii.isAlphabetic(self.peek())) self.at += 1;
        return self.at - start >= 3;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, with the hours at most `max_hours`.
    fn duration(self: *PosixParser, max_hours: i32) ?i32 {
        var sign: i32 = 1;
        if (self.take('-')) sign = -1 else _ = self.take('+');
        const hours = self.number(3) orelse return null;
        if (hours > max_hours) return null;
        var seconds = hours * 3600;
        if (self.take(':')) {
            const minutes = self.number(2) orelse return null;
            if (minutes > 59) return null;
            seconds += minutes * 60;
            if (self.take(':')) {
                const extra = self.number(2) orelse return null;
                if (extra > 59) return null;
                seconds += extra;
            }
        }
        return sign * seconds;
    }

    fn number(self: *PosixParser, max_digits: usize) ?i32 {
        const start = self.at;
        while (!self.done() and std.ascii.isDigit(self.peek()) and self.at - start < max_digits) self.at += 1;
        if (self.at == start) return null;
        return std.fmt.parseInt(i32, self.text[start..self.at], 10) catch null;
    }

    fn change(self: *PosixParser) ?Posix.Change {
        const date: Posix.Date = if (self.take('M')) blk: {
            const month = self.number(2) orelse return null;
            if (!self.take('.')) return null;
            const week = self.number(1) orelse return null;
            if (!self.take('.')) return null;
            const weekday = self.number(1) orelse return null;
            if (month < 1 or month > 12 or week < 1 or week > 5 or weekday > 6) return null;
            break :blk .{ .month_week_day = .{ .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) } };
        } else if (self.take('J')) blk: {
            const day = self.number(3) orelse return null;
            if (day < 1 or day > 365) return null;
            break :blk .{ .julian = @intCast(day) };
        } else blk: {
            const day = self.number(3) orelse return null;
            if (day > 365) return null;
            break :blk .{ .zero_based = @intCast(day) };
        };
        var result: Posix.Change = .{ .date = date };
        if (self.take('/')) result.time = self.duration(167) orelse return null;
        return result;
    }
};

/// Seconds since 1970-01-01T00:00:00 on the local clock at `change` in `year`.
fn localSeconds(year: i64, change: Posix.Change) i64 {
    const day: i64 = switch (change.date) {
        .month_week_day => |rule| blk: {
            const first = daysFromCivil(year, rule.month, 1);
            // 1970-01-01 was a Thursday, weekday 4.
            const first_weekday = @mod(first + 4, 7);
            var day_of_month = 1 + @mod(@as(i64, rule.weekday) - first_weekday, 7) + (@as(i64, rule.week) - 1) * 7;
            while (day_of_month > monthLength(year, rule.month)) day_of_month -= 7;
            break :blk first + day_of_month - 1;
        },
        .julian => |day| daysFromCivil(year, 1, 1) + day - 1 + @as(i64, if (isLeap(year) and day >= 60) 1 else 0),
        .zero_based => |day| daysFromCivil(year, 1, 1) + day,
    };
    return day * std.time.s_per_day + change.time;
}

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthLength(year: i64, month: u8) i64 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Howard Hinnant's days_from_civil, as prelude.em's `_days_from_civil`.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const shifted = if (month <= 2) year - 1 else year;
    const era = @divFloor(shifted, 400);
    const year_of_era = shifted - era * 400;
    const day_of_year = @divFloor(153 * @mod(month + 9, 12) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn civilFromDays(days: i64) struct { year: i64 } {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    return .{ .year = year_of_era + era * 400 + @as(i64, if (month_index >= 10) 1 else 0) };
}

/// The IANA time zone database built into Emerald, so a named zone gives the
/// same answer on every operating system. It is decompressed only when a
/// program first asks for a zone by name. See `tools/update-tzdata.py` for the
/// layout.
pub const Database = struct {
    entries: []const Entry,
    files: []const []const u8,

    const Entry = struct { name: []const u8, file: u16 };

    const compressed = @embedFile("tzdata/zones.zlib");

    /// Everything it returns lives in `arena`.
    pub fn load(arena: std.mem.Allocator) !Database {
        var input: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &window);
        const bytes = try decompress.reader.allocRemaining(arena, .unlimited);

        var reader: std.Io.Reader = .fixed(bytes);
        if (!std.mem.eql(u8, try reader.take(4), "EMTZ") or try reader.takeByte() != 1) return error.BadDatabase;
        const entries = try arena.alloc(Entry, try reader.takeInt(u32, .little));
        for (entries) |*entry| {
            const name = try reader.take(try reader.takeByte());
            entry.* = .{ .name = name, .file = try reader.takeInt(u16, .little) };
        }
        const files = try arena.alloc([]const u8, try reader.takeInt(u32, .little));
        for (files) |*file| file.* = try reader.take(try reader.takeInt(u32, .little));
        for (entries) |entry| if (entry.file >= files.len) return error.BadDatabase;
        return .{ .entries = entries, .files = files };
    }

    /// The TZif file for exactly `name`, which is case-sensitive as IANA's
    /// names are.
    pub fn find(self: Database, name: []const u8) ?[]const u8 {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.entries[middle].name, name)) {
                .eq => return self.files[self.entries[middle].file],
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }

    pub fn rules(self: Database, arena: std.mem.Allocator, name: []const u8) !?Rules {
        const file = self.find(name) orelse return null;
        return try parseTzif(arena, file);
    }

    /// The name meant by one written in the wrong case, such as
    /// `america/new_york`.
    pub fn closest(self: Database, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.name;
        return null;
    }
};

/// CLDR's IANA name for a Windows zone key name such as `Eastern Standard
/// Time`.
pub fn windowsZoneName(key: []const u8) ?[]const u8 {
    for (tzdata.windows) |pair| if (std.mem.eql(u8, pair[0], key)) return pair[1];
    return null;
}

/// Where the machine's zone comes from on a Unix-like system, following
/// glibc: the `TZ` variable when it is set, otherwise `/etc/localtime`.
pub const Source = union(enum) {
    utc,
    /// A TZif file at `path`, known to programs as `name`.
    file: struct { path: []const u8, name: []const u8 },
    /// A zone name looked up in the system's zoneinfo directories, and read
    /// as a POSIX rule when no file has that name.
    named: []const u8,
};

/// `tz` is the `TZ` variable, if set. `localtime_link` is where
/// `/etc/localtime` points when it is a symbolic link.
pub fn localSource(tz: ?[]const u8, localtime_link: ?[]const u8) Source {
    const value = tz orelse return .{ .file = .{
        .path = "/etc/localtime",
        .name = if (localtime_link) |link| zoneNameOf(link) orelse "Local" else "Local",
    } };
    const trimmed = if (std.mem.startsWith(u8, value, ":")) value[1..] else value;
    if (trimmed.len == 0) return .utc;
    if (trimmed[0] == '/') return .{ .file = .{ .path = trimmed, .name = zoneNameOf(trimmed) orelse trimmed } };
    return .{ .named = trimmed };
}

/// `America/New_York` from `/usr/share/zoneinfo/America/New_York`: whatever
/// follows the last `zoneinfo/`.
pub fn zoneNameOf(path: []const u8) ?[]const u8 {
    const marker = "zoneinfo/";
    const index = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    const name = path[index + marker.len ..];
    return if (name.len == 0) null else name;
}

/// Where a named zone's TZif file may be, in the order glibc and macOS look.
pub const zoneinfo_directories = [_][]const u8{
    "/usr/share/zoneinfo/",
    "/usr/lib/zoneinfo/",
    "/usr/share/lib/zoneinfo/",
    "/var/db/timezone/zoneinfo/",
};

/// Windows's own description of the machine's zone (`GetDynamicTimeZoneInformation`),
/// read as a POSIX rule. Biases are minutes west of UTC.
pub fn fromWindows(bias: i32, standard_bias: i32, daylight_bias: i32, standard_date: WindowsDate, daylight_date: WindowsDate) Posix {
    const standard: i32 = -(bias + standard_bias) * 60;
    // A month of zero means the zone has no daylight time; a year other than
    // zero is a one-off date, which this reads as no daylight time too.
    if (daylight_date.month == 0 or standard_date.month == 0 or daylight_date.year != 0 or standard_date.year != 0) return .{ .standard = standard };
    return .{
        .standard = standard,
        .daylight = .{
            .offset = -(bias + daylight_bias) * 60,
            .start = daylight_date.change(),
            .end = standard_date.change(),
        },
    };
}

/// The fields of a Windows `SYSTEMTIME` that describe a yearly change: in
/// month `month`, weekday `weekday` of week `week` (5 is the last).
pub const WindowsDate = struct {
    year: u16 = 0,
    month: u16,
    weekday: u16,
    week: u16,
    hour: u16,
    minute: u16,

    fn change(self: WindowsDate) Posix.Change {
        return .{
            .date = .{ .month_week_day = .{ .month = @intCast(self.month), .week = @intCast(@min(self.week, 5)), .weekday = @intCast(self.weekday) } },
            .time = @as(i32, self.hour) * 3600 + @as(i32, self.minute) * 60,
        };
    }
};

const testing = std.testing;

fn utc(year: i64, month: i64, day: i64, hour: i64, minute: i64) i64 {
    return daysFromCivil(year, month, day) * std.time.s_per_day + hour * 3600 + minute * 60;
}

test "a POSIX rule with United States daylight time" {
    const rule = parsePosix("EST5EDT,M3.2.0,M11.1.0").?;
    try testing.expectEqual(-5 * 3600, rule.standard);
    // 2026 starts daylight time at 02:00 EST on 8 March (07:00 UTC) and ends
    // it at 02:00 EDT on 1 November (06:00 UTC).
    try testing.expectEqual(-5 * 3600, rule.offsetAt(utc(2026, 3, 8, 6, 59)));
    try testing.expectEqual(-4 * 3600, rule.offsetAt(utc(2026, 3, 8, 7, 0)));
    try testing.expectEqual(-4 * 3600, rule.offsetAt(utc(2026, 11, 1, 5, 59)));
    try testing.expectEqual(-5 * 3600, rule.offsetAt(utc(2026, 11, 1, 6, 0)));
    try testing.expectEqual(-5 * 3600, rule.offsetAt(utc(2026, 1, 15, 12, 0)));
}

test "a POSIX rule whose daylight time spans the new year" {
    // Sydney: daylight time from 02:00 on the first Sunday of October to
    // 03:00 daylight time on the first Sunday of April.
    const rule = parsePosix("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try testing.expectEqual(11 * 3600, rule.offsetAt(utc(2026, 1, 15, 0, 0)));
    try testing.expectEqual(10 * 3600, rule.offsetAt(utc(2026, 7, 15, 0, 0)));
    // 5 April 2026 03:00 AEDT is 4 April 16:00 UTC.
    try testing.expectEqual(11 * 3600, rule.offsetAt(utc(2026, 4, 4, 15, 59)));
    try testing.expectEqual(10 * 3600, rule.offsetAt(utc(2026, 4, 4, 16, 0)));
}

test "POSIX rule forms" {
    try testing.expectEqual(@as(i32, 0), parsePosix("UTC0").?.standard);
    try testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), parsePosix("<+0530>-5:30").?.standard);
    try testing.expect(parsePosix("<+0530>-5:30").?.daylight == null);
    // Julian days, with an explicit daylight offset and change times.
    const julian = parsePosix("XXX3YYY2,J60/1:30,300/-1").?;
    try testing.expectEqual(@as(i32, -2 * 3600), julian.daylight.?.offset);
    try testing.expectEqual(@as(i32, -3600), julian.daylight.?.end.time);
    // A daylight name with no dates uses the United States' rules.
    try testing.expectEqual(@as(u8, 3), parsePosix("EST5EDT").?.daylight.?.start.date.month_week_day.month);
    for ([_][]const u8{ "", "E5", "EST", "EST5EDT,M3.2.0", "EST5EDT,M13.2.0,M11.1.0", "America/New_York", "EST25" }) |bad| {
        try testing.expect(parsePosix(bad) == null);
    }
}

test "transitions, then the footer after the last one" {
    const transitions = [_]Transition{
        .{ .at = 100, .offset = 3600 },
        .{ .at = 200, .offset = 7200 },
    };
    const rules: Rules = .{ .initial = 60, .transitions = &transitions, .footer = .{ .standard = -3600 } };
    try testing.expectEqual(@as(i32, 60), rules.offsetAt(99));
    try testing.expectEqual(@as(i32, 3600), rules.offsetAt(100));
    try testing.expectEqual(@as(i32, 3600), rules.offsetAt(199));
    try testing.expectEqual(@as(i32, -3600), rules.offsetAt(200));
    const without_footer: Rules = .{ .initial = 60, .transitions = &transitions };
    try testing.expectEqual(@as(i32, 7200), without_footer.offsetAt(1000));
}

test "a TZif file with transitions and a footer" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    const Header = struct {
        fn write(list: *std.ArrayList(u8), version: u8, timecnt: u32, typecnt: u32, charcnt: u32) !void {
            try list.appendSlice(testing.allocator, "TZif");
            try list.append(testing.allocator, version);
            try list.appendNTimes(testing.allocator, 0, 15);
            for ([_]u32{ 0, 0, 0, timecnt, typecnt, charcnt }) |count| {
                var buffer: [4]u8 = undefined;
                std.mem.writeInt(u32, &buffer, count, .big);
                try list.appendSlice(testing.allocator, &buffer);
            }
        }
    };
    // A minimal version 1 block for readers that stop there: one UTC type.
    try Header.write(&bytes, '2', 0, 1, 4);
    try bytes.appendSlice(testing.allocator, &.{ 0, 0, 0, 0, 0, 0 });
    try bytes.appendSlice(testing.allocator, "UTC\x00");
    // The version 2 block: LMT until 1000, then EST, then the footer's rule.
    try Header.write(&bytes, '2', 1, 2, 8);
    var at: [8]u8 = undefined;
    std.mem.writeInt(i64, &at, 1000, .big);
    try bytes.appendSlice(testing.allocator, &at);
    try bytes.append(testing.allocator, 1);
    for ([_]i32{ -17762, -18000 }, [_]u8{ 0, 4 }) |offset, designation| {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(i32, &buffer, offset, .big);
        try bytes.appendSlice(testing.allocator, &buffer);
        try bytes.appendSlice(testing.allocator, &.{ 0, designation });
    }
    try bytes.appendSlice(testing.allocator, "LMT\x00EST\x00");
    try bytes.appendSlice(testing.allocator, "\nEST5EDT,M3.2.0,M11.1.0\n");

    const rules = try parseTzif(testing.allocator, bytes.items);
    defer rules.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, -17762), rules.offsetAt(999));
    try testing.expectEqual(@as(i32, -4 * 3600), rules.offsetAt(utc(2026, 7, 1, 0, 0)));
    try testing.expectEqual(@as(i32, -5 * 3600), rules.offsetAt(utc(2026, 12, 1, 0, 0)));
}

test "where the machine's zone comes from" {
    try testing.expectEqualStrings("America/New_York", localSource(null, "/usr/share/zoneinfo/America/New_York").file.name);
    try testing.expectEqualStrings("/etc/localtime", localSource(null, null).file.path);
    try testing.expectEqualStrings("Local", localSource(null, null).file.name);
    try testing.expect(localSource("", null) == .utc);
    try testing.expect(localSource(":", null) == .utc);
    try testing.expectEqualStrings("Europe/Paris", localSource(":Europe/Paris", null).named);
    try testing.expectEqualStrings("EST5EDT,M3.2.0,M11.1.0", localSource("EST5EDT,M3.2.0,M11.1.0", null).named);
    const absolute = localSource("/var/db/timezone/zoneinfo/Asia/Tokyo", null).file;
    try testing.expectEqualStrings("Asia/Tokyo", absolute.name);
    try testing.expectEqualStrings("/tmp/zone", localSource("/tmp/zone", null).file.name);
}

test "the built-in database" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const database = try Database.load(arena.allocator());
    try testing.expect(database.entries.len > 400);

    const new_york = (try database.rules(arena.allocator(), "America/New_York")).?;
    try testing.expectEqual(-5 * 3600, new_york.offsetAt(utc(2026, 3, 8, 6, 59)));
    try testing.expectEqual(-4 * 3600, new_york.offsetAt(utc(2026, 3, 8, 7, 0)));
    // Before 1883 New York kept its own local mean time.
    try testing.expectEqual(@as(i32, -17762), new_york.offsetAt(utc(1850, 1, 1, 0, 0)));
    // Well past the last transition, the footer's rule still applies.
    try testing.expectEqual(-4 * 3600, new_york.offsetAt(utc(2300, 7, 1, 0, 0)));

    // Brazil stopped daylight time in 2019.
    const sao_paulo = (try database.rules(arena.allocator(), "America/Sao_Paulo")).?;
    try testing.expectEqual(-2 * 3600, sao_paulo.offsetAt(utc(2019, 1, 15, 0, 0)));
    try testing.expectEqual(-3 * 3600, sao_paulo.offsetAt(utc(2020, 1, 15, 0, 0)));

    try testing.expect(database.find("america/new_york") == null);
    try testing.expectEqualStrings("America/New_York", database.closest("america/new_york").?);
    try testing.expect(database.find("Nowhere/Special") == null);
    try testing.expect(database.closest("Nowhere/Special") == null);
    // Every Windows name maps to a zone the database has.
    for (tzdata.windows) |pair| try testing.expect(database.find(pair[1]) != null);
    try testing.expectEqualStrings("America/New_York", windowsZoneName("Eastern Standard Time").?);
    try testing.expect(windowsZoneName("Nowhere Standard Time") == null);
}

test "Windows's description of a zone" {
    // Eastern Standard Time: bias 300 minutes west, daylight bias -60, from the
    // second Sunday of March at 02:00 to the first Sunday of November at 02:00.
    const rule = fromWindows(
        300,
        0,
        -60,
        .{ .month = 11, .weekday = 0, .week = 1, .hour = 2, .minute = 0 },
        .{ .month = 3, .weekday = 0, .week = 2, .hour = 2, .minute = 0 },
    );
    try testing.expectEqual(-4 * 3600, rule.offsetAt(utc(2026, 7, 1, 0, 0)));
    try testing.expectEqual(-5 * 3600, rule.offsetAt(utc(2026, 1, 1, 0, 0)));
    const india = fromWindows(-330, 0, 0, .{ .month = 0, .weekday = 0, .week = 0, .hour = 0, .minute = 0 }, .{ .month = 0, .weekday = 0, .week = 0, .hour = 0, .minute = 0 });
    try testing.expectEqual(@as(i32, 330 * 60), india.offsetAt(0));
    try testing.expect(india.daylight == null);
}
