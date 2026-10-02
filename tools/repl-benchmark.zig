//! ReleaseSafe analysis profile, deliberately not a timing assertion in CI.
//! zig build repl-benchmark -j1 -Doptimize=ReleaseSafe
const std = @import("std");
const emerald = @import("emerald");

fn median(samples: []i96) i96 {
    std.mem.sort(i96, samples, {}, std.sort.asc(i96));
    return samples[samples.len / 2];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var syntax: emerald.SessionSyntax = .{};
    defer syntax.deinit(gpa);
    std.debug.print("entry  total analysis ms  resolve ms  check ms (9 samples)\n", .{});
    for (1..1001) |number| {
        const text = try std.fmt.allocPrint(gpa, "const job_{d} = {{ => 1 }}\n", .{number});
        defer gpa.free(text);
        _ = try syntax.append(gpa, text);
        if (number != 5 and number != 100 and number != 500 and number != 1000) continue;
        // Warm the code/data before collecting medians. Each sample resolves
        // and checks exactly the same kept nodes, then frees its analysis.
        var warm = (try emerald.analyzeSession(gpa, &syntax)).?;
        warm.deinit(gpa);
        var totals: [9]i96 = undefined;
        var resolves: [9]i96 = undefined;
        var checks: [9]i96 = undefined;
        for (&totals, &resolves, &checks) |*total, *resolved, *checked| {
            var stages: emerald.SessionTimings = .{};
            const start = std.Io.Clock.awake.now(init.io).toNanoseconds();
            var analysis = (try emerald.analyzeSessionWithOptions(gpa, &syntax, .{ .timings = &stages })).?;
            total.* = std.Io.Clock.awake.now(init.io).toNanoseconds() - start;
            resolved.* = stages.resolve_ns;
            checked.* = stages.check_ns;
            if (!analysis.ok()) return error.InvalidBenchmark;
            analysis.deinit(gpa);
        }
        const total = median(&totals);
        std.debug.print("{d:4}  {d:17.3}  {d:10.3}  {d:8.3}\n", .{ number, @as(f64, @floatFromInt(total)) / 1e6, @as(f64, @floatFromInt(median(&resolves))) / 1e6, @as(f64, @floatFromInt(median(&checks))) / 1e6 });
        // Local development budget only: this tool is not a CI test step.
        if (number == 500 and total >= 100 * std.time.ns_per_ms) return error.AnalysisBudgetExceeded;
    }
}
