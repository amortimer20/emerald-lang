//! The immutable integer sequence behind Emerald's `..`, `..<`, `up_to`, and
//! `down_to` forms. It is deliberately independent of loops so Range values and
//! `for` can share one overflow-safe definition of the values they visit.

const std = @import("std");

pub const Range = struct {
    first: i64,
    last: i64,
    step_size: i64 = 1,
    descending: bool = false,
    /// An empty range cannot be told apart from a single-value count by its
    /// endpoints alone, so this keeps the count semantics exact.
    is_empty: bool = false,
    /// For an empty range only, what display needs to print it as written, so
    /// the bounds that made it empty show: whether it was written `a..<b`
    /// (`first` and `last` are then `a` and `b`), and whether it has been
    /// reversed (which leaves it empty, so its direction is not flipped).
    exclusive: bool = false,
    reversed: bool = false,

    pub fn fromBounds(start: i64, end: i64, inclusive: bool) Range {
        if (inclusive) {
            if (start > end) return .{ .first = start, .last = end, .is_empty = true };
            return .{ .first = start, .last = end };
        }
        if (start >= end) return .{ .first = start, .last = end, .exclusive = true, .is_empty = true };
        return .{ .first = start, .last = end - 1 };
    }

    pub fn fromTarget(start: i64, end: i64, descending: bool) Range {
        if (descending) {
            if (start < end) return .{ .first = start, .last = end, .descending = true, .is_empty = true };
            return .{ .first = start, .last = end, .descending = true };
        }
        if (start > end) return .{ .first = start, .last = end, .is_empty = true };
        return .{ .first = start, .last = end };
    }

    pub fn empty(self: Range) bool {
        return self.is_empty;
    }

    /// The exact number of values. The full Int domain has 2^64 values, one
    /// more than a `u64`, so internal consumers must not narrow this early.
    pub fn length(self: Range) u128 {
        if (self.is_empty) return 0;
        const distance: i128 = if (self.descending)
            @as(i128, self.first) - self.last
        else
            @as(i128, self.last) - self.first;
        const steps = @divTrunc(distance, @as(i128, self.step_size));
        return @intCast(steps + 1);
    }

    /// `Range.count` is an Int property in Emerald. An all-Int range has one
    /// value too many for that result type, so the interpreter explains that
    /// case rather than silently truncating or saturating it.
    pub fn count(self: Range) ?i64 {
        return std.math.cast(i64, self.length());
    }

    pub fn reaching(first: i64, bound: i64, step_distance: i64, descending: bool) Range {
        const difference = @as(i128, bound) - first;
        const distance: i128 = if (difference < 0) -difference else difference;
        const whole = distance - @rem(distance, step_distance);
        return .{
            .first = first,
            .last = @intCast(if (descending) @as(i128, first) - whole else @as(i128, first) + whole),
            .step_size = step_distance,
            .descending = descending,
        };
    }

    pub fn step(self: Range, distance: i64) Range {
        if (self.is_empty) {
            var stepped = self;
            stepped.step_size = distance;
            return stepped;
        }
        return reaching(self.first, self.last, distance, self.descending);
    }

    pub fn reverse(self: Range) Range {
        if (self.is_empty) {
            var reversed = self;
            reversed.reversed = !self.reversed;
            return reversed;
        }
        return .{ .first = self.last, .last = self.first, .step_size = self.step_size, .descending = !self.descending };
    }

    pub fn toList(self: Range, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{RangeTooLarge})![]const i64 {
        if (self.is_empty) return &.{};
        const count_value = self.count() orelse return error.RangeTooLarge;
        const size = std.math.cast(usize, count_value) orelse return error.RangeTooLarge;
        const items = try allocator.alloc(i64, size);
        errdefer allocator.free(items);
        var current = self.first;
        for (items) |*slot| {
            slot.* = current;
            if (current == self.last) break;
            current = if (self.descending) current - self.step_size else current + self.step_size;
        }
        return items;
    }
};

test "range reaches exactly reachable endpoints without overflow" {
    const range = Range.reaching(10, 0, 4, true);
    try std.testing.expectEqual(@as(i64, 10), range.first);
    try std.testing.expectEqual(@as(i64, 2), range.last);
}

test "reversing range swaps the visited sequence" {
    const range = Range.fromTarget(0, 10, false).reverse();
    try std.testing.expectEqual(@as(i64, 10), range.first);
    try std.testing.expectEqual(@as(i64, 0), range.last);
    try std.testing.expect(range.descending);
}

test "an empty range keeps what display needs" {
    const exclusive = Range.fromBounds(0, 0, false);
    try std.testing.expect(exclusive.empty() and exclusive.exclusive);
    try std.testing.expectEqual(@as(i64, 0), exclusive.last);
    const reversed = Range.fromBounds(1, 0, true).reverse();
    try std.testing.expect(reversed.empty() and reversed.reversed and !reversed.descending);
}
