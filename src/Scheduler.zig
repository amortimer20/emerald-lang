//! The scheduler seam for structured Emerald tasks.
//!
//! Slice 1 has one task only.  The baton and task-state wrapper are deliberately
//! small, but keep ownership of the hand-off protocol out of the interpreter so
//! an OS-thread scheduler (and, later, a fiber backend) can replace them without
//! changing language code.

const std = @import("std");

/// Exactly one task owns the baton in this slice.  `anyopaque` keeps this file
/// independent of Interpreter's per-task state type.
pub const Baton = struct {
    owner: ?*anyopaque = null,
    held: bool = false,

    pub fn init(task: *anyopaque) Baton {
        return .{ .owner = task, .held = true };
    }

    pub fn save(self: *Baton, task: *anyopaque) void {
        std.debug.assert(self.owner == task and self.held);
        self.held = false;
    }

    pub fn load(self: *Baton, task: *anyopaque) void {
        std.debug.assert(self.owner == task and !self.held);
        self.held = true;
    }
};

/// A typed container for the state that will travel with a task.  Save/load are
/// explicit even while there is only one task, so the future scheduler can swap
/// complete interpreter states at one suspension point.
pub fn TaskState(comptime State: type) type {
    return struct {
        state: State,

        pub fn save(self: *@This(), baton: *Baton) void {
            baton.save(self);
        }

        pub fn load(self: *@This(), baton: *Baton) void {
            baton.load(self);
        }
    };
}

test "a task can save and load the single-task baton" {
    const State = struct { value: u8 };
    var task = TaskState(State){ .state = .{ .value = 42 } };
    var baton = Baton.init(&task);
    task.save(&baton);
    task.load(&baton);
    try std.testing.expectEqual(@as(u8, 42), task.state.value);
    try std.testing.expect(baton.held);
}

/// One OS thread per live task, but only the baton holder may enter Emerald.
/// All queueing and host-thread synchronization stays behind this seam.
pub const Runtime = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    current: ?*Job,
    ready_head: ?*Job = null,
    ready_tail: ?*Job = null,
    all: *Job,
    next_wait_order: usize = 1,

    /// A generous virtual stack reservation; physical pages are committed as
    /// the task uses them. The measured live-task cap limits total reservation.
    pub const stack_size: usize = if (@sizeOf(usize) >= 8) 128 * 1024 * 1024 else 32 * 1024 * 1024;

    pub const Job = struct {
        condition: std.Io.Condition = .init,
        status: enum { running, ready, waiting, done } = .running,
        thread: ?std.Thread = null,
        ready_next: ?*Job = null,
        all_next: ?*Job = null,
        waiting_on: ?*Job = null,
        wait_order: usize = 0,
        deadlocked: bool = false,
        context: ?*anyopaque = null,
        run: ?*const fn (*anyopaque, *Job) void = null,
    };

    pub fn init(io: std.Io, root: *Job) Runtime {
        root.* = .{};
        return .{ .io = io, .current = root, .all = root };
    }

    fn enqueue(self: *Runtime, job: *Job) void {
        job.status = .ready;
        job.ready_next = null;
        if (self.ready_tail) |tail| tail.ready_next = job else self.ready_head = job;
        self.ready_tail = job;
    }

    fn dispatch(self: *Runtime) bool {
        const next = self.ready_head orelse {
            self.current = null;
            return false;
        };
        self.ready_head = next.ready_next;
        if (self.ready_head == null) self.ready_tail = null;
        next.ready_next = null;
        next.status = .running;
        self.current = next;
        next.condition.signal(self.io);
        return true;
    }

    /// The holder starts a child; it stays queued until the holder waits.
    pub fn start(self: *Runtime, job: *Job, context: *anyopaque, run: *const fn (*anyopaque, *Job) void) std.Thread.SpawnError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        job.* = .{ .status = .ready, .context = context, .run = run };
        const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, worker, .{ self, job });
        job.thread = thread;
        job.all_next = self.all.all_next;
        self.all.all_next = job;
        self.enqueue(job);
    }

    fn worker(self: *Runtime, job: *Job) void {
        self.mutex.lockUncancelable(self.io);
        while (job.status != .running) job.condition.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
        job.run.?(job.context.?, job);
        self.finish(job);
    }

    fn finish(self: *Runtime, job: *Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == job);
        job.status = .done;
        // Wake result waiters in the order they parked, not in the linked
        // list's (reverse-start) order. The live-task cap keeps this tiny.
        while (true) {
            var first: ?*Job = null;
            var item: ?*Job = self.all;
            while (item) |waiting| : (item = waiting.all_next) {
                if (waiting.status != .waiting or waiting.waiting_on != job) continue;
                if (first == null or waiting.wait_order < first.?.wait_order) first = waiting;
            }
            const waiting = first orelse break;
            waiting.waiting_on = null;
            self.enqueue(waiting);
        }
        _ = self.dispatch();
    }

    /// Park the current holder until `target` finishes. False means there is
    /// no runnable task that could make progress, rather than hanging forever.
    pub fn waitFor(self: *Runtime, current: *Job, target: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        if (target.status == .done) return true;
        current.status = .waiting;
        current.waiting_on = target;
        current.wait_order = self.next_wait_order;
        self.next_wait_order += 1;
        if (!self.dispatch()) {
            current.status = .running;
            current.waiting_on = null;
            self.current = current;
            // Every task is waiting and none can complete. Wake the others
            // with the same verdict so the group can unwind and join them.
            while (true) {
                var first: ?*Job = null;
                var item: ?*Job = self.all;
                while (item) |waiting| : (item = waiting.all_next) {
                    if (waiting == current or waiting.status != .waiting) continue;
                    if (first == null or waiting.wait_order < first.?.wait_order) first = waiting;
                }
                const waiting = first orelse break;
                waiting.deadlocked = true;
                waiting.waiting_on = null;
                self.enqueue(waiting);
            }
            return false;
        }
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
        const deadlocked = current.deadlocked;
        current.deadlocked = false;
        return !deadlocked;
    }

    /// Voluntarily hand the baton to the next ready task. A lone task keeps it.
    pub fn yield(self: *Runtime, current: *Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        if (self.ready_head == null) return;
        self.enqueue(current);
        _ = self.dispatch();
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
    }

    pub fn isDone(self: *Runtime, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return job.status == .done;
    }

    /// Every started thread must be joined, including a completed task whose
    /// Emerald handle escaped its group.
    pub fn join(_: *Runtime, job: *Job) void {
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }
};

test "a waiting task hands the baton to its child" {
    const Probe = struct {
        fn run(context: *anyopaque, _: *Runtime.Job) void {
            const number: *u8 = @ptrCast(@alignCast(context));
            number.* = 42;
        }
    };
    var root: Runtime.Job = undefined;
    var runtime = Runtime.init(std.Io.Threaded.global_single_threaded.io(), &root);
    var child: Runtime.Job = undefined;
    var number: u8 = 0;
    try runtime.start(&child, &number, Probe.run);
    try std.testing.expect(runtime.waitFor(&root, &child));
    runtime.join(&child);
    try std.testing.expectEqual(@as(u8, 42), number);
}
