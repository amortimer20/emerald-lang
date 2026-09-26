//! Answers regular-expression queries for `tools/regex-differential.py`: one
//! JSON object per input line, `{"pattern", "text", "ignore_case"}`, and one
//! JSON line back, the first match's group spans in graphemes, `"match":
//! null`, or the refusal's message.
//!
//!   zig run --dep regex -Mroot=tools/regex_probe.zig -Mregex=src/Regex.zig

const std = @import("std");
const Regex = @import("regex");

const Query = struct {
    pattern: []const u8,
    text: []const u8,
    ignore_case: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &stdout.interface;

    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var parsed = try std.json.parseFromSlice(Query, gpa, line, .{});
        defer parsed.deinit();
        const query = parsed.value;

        var problem: Regex.Problem = .{};
        var program = Regex.compile(gpa, query.pattern, .{ .ignore_case = query.ignore_case }, &problem) catch |err| switch (err) {
            error.InvalidPattern => {
                try out.writeAll("{\"error\":");
                try std.json.Stringify.value(problem.message(), .{}, out);
                try out.writeAll("}\n");
                continue;
            },
            else => return err,
        };
        defer program.deinit();
        const text = try Regex.Text.init(gpa, query.text);
        defer text.deinit(gpa);
        const slots = try gpa.alloc(usize, program.slotCount());
        defer gpa.free(slots);
        if (!try Regex.run(&program, gpa, text, 0, .search, slots)) {
            try out.writeAll("{\"match\":null}\n");
            continue;
        }
        try out.writeAll("{\"match\":[");
        for (0..program.group_count + 1) |number| {
            if (number > 0) try out.writeAll(",");
            const start = slots[2 * number];
            const end = slots[2 * number + 1];
            if (start == Regex.unset or end == Regex.unset) {
                try out.writeAll("null");
            } else {
                try out.print("[{d},{d}]", .{ start, end });
            }
        }
        try out.writeAll("]}\n");
    }
    try out.flush();
}
