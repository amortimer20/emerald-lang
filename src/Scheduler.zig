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
