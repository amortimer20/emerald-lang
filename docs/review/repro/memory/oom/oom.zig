//! For each program given, counts its allocations in a clean run, then reruns
//! it with allocation N failing, for every N (or every `--stride`th). Each
//! rerun uses a fresh DebugAllocator so a leak or double free at that index
//! is reported with the index. A panic stops the harness at that index.
const std = @import("std");
const emerald = @import("emerald");

fn once(backing: std.mem.Allocator, path: []const u8, text: []const u8, fail_index: ?usize, count: *usize) !bool {
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index orelse std.math.maxInt(usize) });
    const gpa = failing.allocator();
    defer count.* = failing.alloc_index;
    var source = emerald.Source.init(gpa, path, text) catch return false;
    defer source.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(backing);
    defer out.deinit();
    var in: std.Io.Reader = .fixed("");
    var report = emerald.run(gpa, &source, .{ .out = &out.writer, .in = &in }) catch |err| {
        if (fail_index == null) std.debug.print("{s}: clean run failed: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer report.deinit();
    return true;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stride: usize = 1;
    var only: ?usize = null;
    var from: usize = 0;
    var bad: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stride")) {
            i += 1;
            stride = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--from")) {
            i += 1;
            from = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--only")) {
            i += 1;
            only = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        const path = args[i];
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 24));
        defer init.gpa.free(text);
        var total: usize = 0;
        {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            _ = try once(dbg.allocator(), path, text, null, &total);
            if (dbg.deinit() == .leak) {
                std.debug.print("{s}: LEAK on clean run\n", .{path});
                bad += 1;
            }
        }
        var leaks: usize = 0;
        var n: usize = only orelse from;
        if (only != null) total = n + 1;
        // Large programs are sampled: at most about 1,500 failure points each.
        const step = @max(stride, total / 1500);
        while (n < total) : (n += step) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var c: usize = 0;
            // Printed first, so a crash's log names the failing allocation.
            std.debug.print("failing allocation {d}\n", .{n});
            _ = try once(dbg.allocator(), path, text, n, &c);
            if (dbg.deinit() == .leak) {
                std.debug.print("{s}: LEAK when allocation {d} fails\n", .{ path, n });
                leaks += 1;
            }
        }
        bad += leaks;
        std.debug.print("{s}: {d} allocations, stride {d}, {d} leaking indices\n", .{ path, total, step, leaks });
    }
    return if (bad == 0) 0 else 1;
}
