//! Answers CSV documents for `tools/csv/differential.py`: one JSON query per
//! input line, `{"text": "...", "separator": ","}`, and either the parsed
//! rows or an error. The Python tool compares accepted rows to `csv.reader`.
//!
//!   zig run --dep csv -Mroot=tools/csv/probe.zig -Mcsv=src/Csv.zig

const std = @import("std");
const Csv = @import("csv");

const Query = struct {
    text: []const u8,
    separator: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var in_buffer: [256 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    var out_buffer: [256 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &stdout.interface;

    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var parsed = try std.json.parseFromSlice(Query, gpa, line, .{});
        defer parsed.deinit();
        var problem: Csv.Problem = .{};
        var document = Csv.parse(gpa, parsed.value.text, parsed.value.separator, &problem) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidCsv => {
                try out.writeAll("{\"error\":");
                try std.json.Stringify.value(problem.message(), .{}, out);
                try out.writeAll("}\n");
                continue;
            },
        };
        defer document.deinit();
        try out.writeAll("{\"ok\":[");
        for (document.rows, 0..) |row, row_index| {
            if (row_index != 0) try out.writeByte(',');
            try out.writeByte('[');
            for (row.fields, 0..) |field, field_index| {
                if (field_index != 0) try out.writeByte(',');
                try std.json.Stringify.value(field, .{}, out);
            }
            try out.writeByte(']');
        }
        try out.writeAll("]}\n");
    }
    try out.flush();
}
