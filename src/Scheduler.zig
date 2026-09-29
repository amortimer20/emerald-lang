//! The scheduler seam for structured Emerald tasks.
//!
//! One task holds the baton while evaluating Emerald. Threads, timers, host
//! waits, and resource gates stay here so a later fiber backend can replace
//! their implementation without changing language code.

const std = @import("std");

/// Host I/O can allocate while another task evaluates Emerald. Keep that
/// safe even when the embedding caller supplied a non-thread-safe allocator.
pub const SharedAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn allocator(self: *SharedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SharedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret_addr: usize) bool {
        const self: *SharedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret_addr: usize) ?[*]u8 {
        const self: *SharedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SharedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

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
    timer_thread: ?std.Thread = null,
    timer_event: std.Io.Event = .unset,
    stopping: bool = false,
    timers: ?*Job = null,

    /// A generous virtual stack reservation; physical pages are committed as
    /// the task uses them. The measured live-task cap limits total reservation.
    pub const stack_size: usize = if (@sizeOf(usize) >= 8) 128 * 1024 * 1024 else 32 * 1024 * 1024;

    pub const Job = struct {
        condition: std.Io.Condition = .init,
        status: enum { running, ready, waiting, external, done } = .running,
        thread: ?std.Thread = null,
        ready_next: ?*Job = null,
        all_next: ?*Job = null,
        waiting_on: ?*Job = null,
        wait_order: usize = 0,
        deadlocked: bool = false,
        deadlock_target: ?*Job = null,
        wait_site: ?WaitSite = null,
        deadlock_site: ?WaitSite = null,
        deadline: ?i96 = null,
        timer_next: ?*Job = null,
        gate_next: ?*Job = null,
        timed_out: bool = false,
        context: ?*anyopaque = null,
        run: ?*const fn (*anyopaque, *Job) void = null,
    };

    pub const WaitResult = enum { finished, timed_out, deadlocked };
    pub const WaitSite = struct { file: u32, start: u32 };

    /// A native resource has one active operation. Its gate is managed under
    /// the baton, so buffered readers and live handles never race with close.
    pub const Gate = struct {
        owner: ?*Job = null,
        head: ?*Job = null,
        tail: ?*Job = null,
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
        // Deadlock can become visible when the last runnable task finishes,
        // as well as when a task parks. Detect it at every hand-off.
        if (self.ready_head == null and !self.canProgress()) self.wakeDeadlocked();
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

    fn wakeDeadlocked(self: *Runtime) void {
        var item: ?*Job = self.all;
        while (item) |job| : (item = job.all_next) {
            job.deadlock_target = null;
            job.deadlock_site = null;
        }
        while (true) {
            var first: ?*Job = null;
            item = self.all;
            while (item) |job| : (item = job.all_next) {
                if (job.status != .waiting) continue;
                if (first == null or job.wait_order < first.?.wait_order) first = job;
            }
            const job = first orelse break;
            job.deadlocked = true;
            job.deadlock_target = job.waiting_on;
            job.deadlock_site = job.wait_site;
            job.waiting_on = null;
            self.enqueue(job);
        }
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
            self.removeTimer(waiting);
            waiting.waiting_on = null;
            self.enqueue(waiting);
        }
        _ = self.dispatch();
    }

    /// Park the current holder until `target` finishes. False means there is
    /// no runnable task that could make progress, rather than hanging forever.
    pub fn waitFor(self: *Runtime, current: *Job, target: *Job) bool {
        return self.waitForUntil(current, target, null) == .finished;
    }

    pub fn waitForUntil(self: *Runtime, current: *Job, target: *Job, deadline: ?i96) WaitResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        if (target.status == .done) return .finished;
        if (deadline) |end| if (end <= self.now()) return .timed_out;
        current.status = .waiting;
        current.waiting_on = target;
        current.wait_order = self.next_wait_order;
        self.next_wait_order += 1;
        current.timed_out = false;
        if (deadline) |end| self.addTimer(current, end);
        _ = self.dispatch();
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
        const deadlocked = current.deadlocked;
        current.deadlocked = false;
        if (deadlocked) return .deadlocked;
        return if (current.timed_out) .timed_out else .finished;
    }

    fn now(self: *Runtime) i96 {
        return std.Io.Clock.awake.now(self.io).toNanoseconds();
    }

    /// Start lazily, so a program that never waits on time creates no thread.
    pub fn prepareTimers(self: *Runtime) std.Thread.SpawnError!void {
        if (self.timer_thread == null) self.timer_thread = try std.Thread.spawn(.{}, timerMain, .{self});
    }

    fn addTimer(self: *Runtime, job: *Job, deadline: i96) void {
        std.debug.assert(self.timer_thread != null and job.deadline == null);
        job.deadline = deadline;
        var cursor = &self.timers;
        while (cursor.*) |other| {
            if (other.deadline.? > deadline) break;
            cursor = &other.timer_next;
        }
        job.timer_next = cursor.*;
        cursor.* = job;
        self.timer_event.set(self.io);
    }

    fn removeTimer(self: *Runtime, job: *Job) void {
        if (job.deadline == null) return;
        var cursor = &self.timers;
        while (cursor.*) |other| {
            if (other == job) {
                cursor.* = other.timer_next;
                other.timer_next = null;
                other.deadline = null;
                return;
            }
            cursor = &other.timer_next;
        }
        unreachable;
    }

    fn timerMain(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.stopping) {
            const time = self.now();
            while (self.timers) |job| {
                if (job.deadline.? > time) break;
                self.removeTimer(job);
                job.timed_out = job.waiting_on != null;
                job.waiting_on = null;
                self.enqueue(job);
            }
            if (self.current == null) _ = self.dispatch();
            const timeout: std.Io.Timeout = if (self.timers) |job|
                .{ .duration = .{ .raw = .fromNanoseconds(@max(0, job.deadline.? - self.now())), .clock = .awake } }
            else
                .none;
            self.timer_event.reset();
            self.mutex.unlock(self.io);
            self.timer_event.waitTimeout(self.io, timeout) catch {};
            self.mutex.lockUncancelable(self.io);
        }
    }

    pub fn sleepUntil(self: *Runtime, current: *Job, deadline: i96) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        current.status = .waiting;
        self.addTimer(current, deadline);
        _ = self.dispatch();
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
    }

    fn canProgress(self: *Runtime) bool {
        if (self.timers != null) return true;
        var item: ?*Job = self.all;
        while (item) |job| : (item = job.all_next) {
            if (job.status == .external) return true;
        }
        return false;
    }

    pub fn beginExternal(self: *Runtime, current: *Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        current.status = .external;
        _ = self.dispatch();
    }

    pub fn acquire(self: *Runtime, current: *Job, gate: *Gate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current);
        if (gate.owner == null) {
            gate.owner = current;
            return;
        }
        std.debug.assert(gate.owner != current);
        current.status = .waiting;
        current.gate_next = null;
        if (gate.tail) |tail| tail.gate_next = current else gate.head = current;
        gate.tail = current;
        _ = self.dispatch();
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
        std.debug.assert(gate.owner == current);
    }

    pub fn release(self: *Runtime, current: *Job, gate: *Gate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.current == current and gate.owner == current);
        const next = gate.head orelse {
            gate.owner = null;
            return;
        };
        gate.head = next.gate_next;
        if (gate.head == null) gate.tail = null;
        next.gate_next = null;
        gate.owner = next;
        self.enqueue(next);
    }

    pub fn endExternal(self: *Runtime, current: *Job) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(current.status == .external);
        self.enqueue(current);
        if (self.current == null) _ = self.dispatch();
        while (current.status != .running) current.condition.waitUncancelable(self.io, &self.mutex);
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.timer_event.set(self.io);
        self.mutex.unlock(self.io);
        if (self.timer_thread) |thread| thread.join();
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

test "timed waits wake before a later sleeping task" {
    const Probe = struct {
        fn run(context: *anyopaque, job: *Runtime.Job) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            runtime.sleepUntil(job, runtime.now() + 10 * std.time.ns_per_ms);
        }
    };
    var root: Runtime.Job = undefined;
    var runtime = Runtime.init(std.Io.Threaded.global_single_threaded.io(), &root);
    defer runtime.deinit();
    try runtime.prepareTimers();
    var child: Runtime.Job = undefined;
    try runtime.start(&child, &runtime, Probe.run);
    try std.testing.expectEqual(Runtime.WaitResult.timed_out, runtime.waitForUntil(&root, &child, runtime.now() + std.time.ns_per_ms));
    try std.testing.expect(runtime.waitFor(&root, &child));
    runtime.join(&child);
}

test "a task waiting on outside work is not a deadlock" {
    const Probe = struct {
        fn run(context: *anyopaque, job: *Runtime.Job) void {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            runtime.beginExternal(job);
            runtime.endExternal(job);
        }
    };
    var root: Runtime.Job = undefined;
    var runtime = Runtime.init(std.Io.Threaded.global_single_threaded.io(), &root);
    var child: Runtime.Job = undefined;
    try runtime.start(&child, &runtime, Probe.run);
    try std.testing.expect(runtime.waitFor(&root, &child));
    runtime.join(&child);
}

test "equal sleep deadlines resume in waiting order" {
    const Probe = struct {
        runtime: *Runtime,
        deadline: i96,
        order: *[3]usize,
        count: *usize,
        number: usize,

        fn run(context: *anyopaque, job: *Runtime.Job) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.runtime.sleepUntil(job, self.deadline);
            self.order[self.count.*] = self.number;
            self.count.* += 1;
        }
    };
    var root: Runtime.Job = undefined;
    var runtime = Runtime.init(std.Io.Threaded.global_single_threaded.io(), &root);
    defer runtime.deinit();
    try runtime.prepareTimers();
    var order: [3]usize = undefined;
    var count: usize = 0;
    var probes: [3]Probe = undefined;
    var jobs: [3]Runtime.Job = undefined;
    const deadline = runtime.now() + std.time.ns_per_ms;
    for (&probes, &jobs, 0..) |*probe, *job, number| {
        probe.* = .{ .runtime = &runtime, .deadline = deadline, .order = &order, .count = &count, .number = number };
        try runtime.start(job, probe, Probe.run);
    }
    for (&jobs) |*job| {
        try std.testing.expect(runtime.waitFor(&root, job));
        runtime.join(job);
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &order);
}
