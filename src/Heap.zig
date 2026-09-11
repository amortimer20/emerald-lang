//! Where list and string storage lives, and how value semantics is kept cheap.
//!
//! Section 8.1 makes a list a value: assignment and argument passing produce an
//! independent list. Section 8.1 also says copies are "a semantic guarantee,
//! not a physical one", so a list is a shared buffer with a count of how many
//! places hold it, and a mutation copies the buffer first only when that count
//! says someone else can see it. Passing a large list to a function, or keeping
//! one in a loop, copies nothing unless both sides go on to change it.
//!
//! The counts must never be too low: that would let a mutation show through a
//! list that is supposed to be independent. They may be too high, which only
//! costs an unneeded copy and keeps a buffer alive until the end of the run.
//! So every new holder retains, and releases happen wherever a holder
//! demonstrably ends. An error unwinding out of an expression can skip a
//! release; `deinit` frees whatever is left, which is why every buffer is also
//! linked into `live`. That list of every allocated buffer is also exactly what
//! section 19.5's collector will walk when it arrives.
//!
//! Value-typed data cannot form a cycle, so counting reclaims lists completely
//! for now. Once classes exist, a cycle can pass through a list, and the
//! collector will have to trace inside these buffers.
//!
//! Strings are simpler: section 9.1 makes them immutable, so a string is
//! shared freely and never copied. It is counted only so that it can be freed.

const std = @import("std");
const Value = @import("Value.zig");

const Heap = @This();

pub const List = struct {
    /// How many places hold this buffer: bindings, list elements, and values
    /// in flight during evaluation.
    references: u32 = 1,
    items: std.ArrayList(Value) = .empty,
    /// The kind every element has. Static types are gone at runtime, but a
    /// `[Float]` still has to store `rates.append(2)` as `2.0` (4.4), so the
    /// buffer remembers what it holds.
    element: Value.Kind,
    /// Neighbors in `live`.
    previous: ?*List = null,
    next: ?*List = null,
};

/// A string's bytes, which never change once it exists.
pub const Text = struct {
    references: u32 = 1,
    /// A string literal's text, which lives in the syntax tree for the whole
    /// run. It is shared by every evaluation of the literal and never counted.
    literal: bool = false,
    bytes: []const u8,
    /// Neighbors in `live_texts`.
    previous: ?*Text = null,
    next: ?*Text = null,
};

gpa: std.mem.Allocator,
/// Every buffer not yet freed.
live: ?*List = null,
/// Every string not yet freed.
live_texts: ?*Text = null,

pub fn init(gpa: std.mem.Allocator) Heap {
    return .{ .gpa = gpa };
}

/// Frees every buffer still allocated, whatever its count says.
pub fn deinit(self: *Heap) void {
    var cursor = self.live;
    while (cursor) |list| {
        cursor = list.next;
        list.items.deinit(self.gpa);
        self.gpa.destroy(list);
    }
    var texts = self.live_texts;
    while (texts) |text| {
        texts = text.next;
        self.destroyText(text);
    }
    self.* = undefined;
}

/// A string that owns `bytes`, which must come from `gpa` and be valid UTF-8,
/// with one holder, the caller. On failure `bytes` is freed.
pub fn createText(self: *Heap, bytes: []const u8) std.mem.Allocator.Error!*Text {
    const text = self.gpa.create(Text) catch |err| {
        self.gpa.free(bytes);
        return err;
    };
    text.* = .{ .bytes = bytes };
    self.linkText(text);
    return text;
}

/// A string for a literal's text, which the syntax tree keeps alive.
pub fn literalText(self: *Heap, bytes: []const u8) std.mem.Allocator.Error!*Text {
    const text = try self.gpa.create(Text);
    text.* = .{ .bytes = bytes, .literal = true };
    self.linkText(text);
    return text;
}

/// A string holding a copy of `bytes`.
pub fn copyText(self: *Heap, bytes: []const u8) std.mem.Allocator.Error!Value {
    const owned = try self.gpa.dupe(u8, bytes);
    return .{ .data = .{ .string = try self.createText(owned) } };
}

fn linkText(self: *Heap, text: *Text) void {
    text.next = self.live_texts;
    if (self.live_texts) |first| first.previous = text;
    self.live_texts = text;
}

fn destroyText(self: *Heap, text: *Text) void {
    if (!text.literal) self.gpa.free(text.bytes);
    self.gpa.destroy(text);
}

/// An empty list of `element` values with one holder, the caller.
pub fn createList(self: *Heap, element: Value.Kind, capacity: usize) std.mem.Allocator.Error!*List {
    const list = try self.gpa.create(List);
    list.* = .{ .element = element };
    list.items.ensureTotalCapacity(self.gpa, capacity) catch |err| {
        self.gpa.destroy(list);
        return err;
    };
    list.next = self.live;
    if (self.live) |first| first.previous = list;
    self.live = list;
    return list;
}

/// Records a new holder of `value`, and returns it for convenience.
pub fn retain(value: Value) Value {
    switch (value.data) {
        .list => |list| list.references += 1,
        .string => |text| if (!text.literal) {
            text.references += 1;
        },
        else => {},
    }
    return value;
}

/// Records that one holder of `value` is gone, freeing the buffer, and what it
/// holds in turn, when it was the last.
pub fn release(self: *Heap, value: Value) void {
    if (value.data == .string) {
        const text = value.data.string;
        if (text.literal) return;
        text.references -= 1;
        if (text.references > 0) return;
        if (text.previous) |previous| previous.next = text.next else self.live_texts = text.next;
        if (text.next) |next| next.previous = text.previous;
        self.destroyText(text);
        return;
    }
    if (value.data != .list) return;
    const list = value.data.list;
    list.references -= 1;
    if (list.references > 0) return;

    for (list.items.items) |item| self.release(item);
    self.unlink(list);
    list.items.deinit(self.gpa);
    self.gpa.destroy(list);
}

/// Makes the list in `slot` safe to change in place: when anything else holds
/// its buffer, the slot gets a copy of its own first. This is copy-on-write,
/// and it is the only place value semantics is enforced at runtime.
pub fn unique(self: *Heap, slot: *Value) std.mem.Allocator.Error!*List {
    const shared = slot.data.list;
    if (shared.references == 1) return shared;

    const copy = try self.createList(shared.element, shared.items.items.len);
    for (shared.items.items) |item| copy.items.appendAssumeCapacity(retain(item));
    shared.references -= 1; // the slot no longer holds it, and someone else does
    slot.* = .{ .data = .{ .list = copy } };
    return copy;
}

fn unlink(self: *Heap, list: *List) void {
    if (list.previous) |previous| previous.next = list.next else self.live = list.next;
    if (list.next) |next| next.previous = list.previous;
}

const testing = std.testing;

fn listOfInts(heap: *Heap, values: []const i64) !Value {
    const list = try heap.createList(.int, values.len);
    for (values) |value| list.items.appendAssumeCapacity(.initInt(value));
    return .{ .data = .{ .list = list } };
}

test "releasing the last holder frees the buffer" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const list = try listOfInts(&heap, &.{ 1, 2 });
    heap.release(list);
    try testing.expect(heap.live == null);
}

test "a shared buffer is copied before it changes, and a sole one is not" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    var original = try listOfInts(&heap, &.{ 1, 2 });
    const before = original.data.list;
    try testing.expectEqual(before, try heap.unique(&original));

    var copy = retain(original);
    const separate = try heap.unique(&copy);
    try testing.expect(separate != original.data.list);
    try separate.items.append(testing.allocator, .initInt(3));
    try testing.expectEqual(@as(usize, 2), original.data.list.items.items.len);
    try testing.expectEqual(@as(u32, 1), original.data.list.references);

    heap.release(copy);
    heap.release(original);
    try testing.expect(heap.live == null);
}

test "buffers a count never released are still freed at the end" {
    var heap: Heap = .init(testing.allocator);
    const leaked = try listOfInts(&heap, &.{1});
    _ = retain(leaked);
    heap.deinit(); // the testing allocator reports anything left behind
}
