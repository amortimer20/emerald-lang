//! Answers JSON documents for `tools/json/differential.py`: one JSON object
//! per input line, `{"text": "..."}`, and one line back — `{"ok": <the
//! document, re-serialized>}` on success, or `{"error": "<message>"}` on
//! refusal. The re-serialized document is itself valid JSON nested directly
//! inside the answer, so the caller need only parse the answer once to get
//! back a native value built the way Emerald's parser understood it.
//!
//!   zig run --dep json -Mroot=tools/json/probe.zig -Mjson=src/Json.zig

const std = @import("std");
const Json = @import("json");

const Query = struct {
    text: []const u8,
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
        const query = parsed.value;

        var problem: Json.Problem = .{};
        var document = Json.parse(gpa, query.text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => {
                try out.writeAll("{\"error\":");
                try std.json.Stringify.value(problem.message(), .{}, out);
                try out.writeAll("}\n");
                continue;
            },
        };
        defer document.deinit();
        try out.writeAll("{\"ok\":");
        try Json.write(document.root, .{}, out);
        try out.writeAll("}\n");
    }
    try out.flush();
}
