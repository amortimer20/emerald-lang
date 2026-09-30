//! Measure 100,000 cooperative baton hand-offs without Emerald program work.
//! Build with `zig build-exe -O ReleaseSafe --dep Scheduler
//! -Mroot=tools/scheduler-benchmark.zig -O ReleaseSafe -MScheduler=src/Scheduler.zig`, then run
//! under a wall clock and peak-memory monitor (`/usr/bin/time -v` on Linux).

const std = @import("std");
const Scheduler = @import("Scheduler");

const Context = struct {
    runtime: *Scheduler.Runtime,

    fn run(context_ptr: *anyopaque, job: *Scheduler.Runtime.Job) void {
        const self: *Context = @ptrCast(@alignCast(context_ptr));
        for (0..50_000) |_| self.runtime.yield(job);
    }
};

pub fn main() !void {
    var root: Scheduler.Runtime.Job = undefined;
    var runtime = Scheduler.Runtime.init(std.Io.Threaded.global_single_threaded.io(), &root);
    var first: Scheduler.Runtime.Job = undefined;
    var second: Scheduler.Runtime.Job = undefined;
    var context: Context = .{ .runtime = &runtime };
    try runtime.start(&first, &context, Context.run);
    try runtime.start(&second, &context, Context.run);
    if (!runtime.waitFor(&root, &first)) return error.Deadlock;
    if (!runtime.waitFor(&root, &second)) return error.Deadlock;
    runtime.join(&first);
    runtime.join(&second);
}
