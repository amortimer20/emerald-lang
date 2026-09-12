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
//! linked into `live`. That list of every allocated buffer is also what the
//! collector walks.
//!
//! Strings are simpler: section 9.1 makes them immutable, so a string is
//! shared freely and never copied. It is counted only so that it can be freed.
//!
//! Section 7.4's closures capture "by reference", so a lambda and the block it
//! was written in must be able to see each other's changes to the same
//! variable. That makes a scope an object rather than a stack frame: an
//! `Environment` is counted like a list, and a block that ends while a closure
//! still holds its environment leaves it alive with the variables intact.
//!
//! Closures are where counting stops being complete. A closure holds its
//! environments, and an environment holds whatever its names hold, so storing a
//! closure in a local makes the two hold each other: `const block = { ... }`
//! puts the closure into the very environment it captured. That is the ordinary
//! way to write one, not an exotic case, so cycles are expected rather than
//! rare, and counting alone would never reclaim one.
//!
//! So counting is only half of it. Section 19.5's mark-and-sweep collector is
//! the other half: `collect` walks `live`, `live_texts`, `live_environments`,
//! and `live_closures` and frees whatever nothing outside the heap can reach.
//! Counting still does the everyday work, freeing promptly and deciding when a
//! list must be copied; collection runs at a threshold and exists for the
//! cycles. `deinit` still frees whatever is left at the end, whatever the counts
//! say.

const std = @import("std");
const Ast = @import("Ast.zig");
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
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live`.
    previous: ?*List = null,
    next: ?*List = null,
};

/// What one name holds, and the kind it holds.
///
/// The kind is carried because section 4.4's widening has to actually happen,
/// not merely be permitted. The checker accepts `var rate: Float = 1` because an
/// `Int` is assignable to a `Float`; if the interpreter then stored the `Int`,
/// the static type and the runtime value would disagree and `rate` would print
/// as `1` rather than `1.0`.
pub const Binding = struct {
    kind: Value.Kind,
    /// Null until section 4.1's definite assignment says otherwise.
    value: ?Value,
};

/// One block's, or one call's, names.
///
/// Counted, because section 7.4 makes a closure capture the variables it can
/// see rather than their values, so the block that declared them may end first.
pub const Environment = struct {
    references: u32 = 1,
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live_environments`.
    previous: ?*Environment = null,
    next: ?*Environment = null,
};

/// A callable value: section 7.4's lambda, with the scopes it captured, or
/// section 7.5's captured named function, which captures nothing because a
/// named function sees only the module.
pub const Closure = struct {
    references: u32 = 1,
    function: Function,
    /// The environments visible where it was written, outermost first. Held,
    /// so they outlive the blocks that created them.
    captured: []*Environment,
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live_closures`.
    previous: ?*Closure = null,
    next: ?*Closure = null,

    pub const Function = union(enum) {
        /// The name of a top-level function.
        named: []const u8,
        /// The `.lambda` expression this runs.
        lambda: *const Ast.Expression,
    };
};

/// A string's bytes, which never change once it exists.
pub const Text = struct {
    references: u32 = 1,
    /// A string literal's text, which lives in the syntax tree for the whole
    /// run. It is shared by every evaluation of the literal and never counted.
    literal: bool = false,
    bytes: []const u8,
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live_texts`.
    previous: ?*Text = null,
    next: ?*Text = null,
};

gpa: std.mem.Allocator,
/// Every buffer not yet freed.
live: ?*List = null,
/// Every string not yet freed.
live_texts: ?*Text = null,
/// Every environment not yet freed.
live_environments: ?*Environment = null,
/// Every closure not yet freed.
live_closures: ?*Closure = null,
/// How many objects are in those four lists.
live_objects: usize = 0,
/// The size `live_objects` must reach for the next collection. Section 19.5
/// asks for "predictable allocation thresholds"; this is one, doubled after
/// each collection so that a program holding many live objects does not pay
/// for a full trace on every allocation.
collect_after: usize = minimum_threshold,
/// The collector's worklist, kept between collections so that tracing rarely
/// allocates after the first one.
work: std.ArrayList(Object) = .empty,

/// Small enough that the collector is exercised by ordinary programs and tests
/// rather than only by large ones.
const minimum_threshold = 4096;

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
    var closures = self.live_closures;
    while (closures) |closure| {
        closures = closure.next;
        self.gpa.free(closure.captured);
        self.gpa.destroy(closure);
    }
    var environments = self.live_environments;
    while (environments) |environment| {
        environments = environment.next;
        environment.bindings.deinit(self.gpa);
        self.gpa.destroy(environment);
    }
    self.work.deinit(self.gpa);
    self.* = undefined;
}

/// An empty environment with one holder, the caller.
pub fn createEnvironment(self: *Heap) std.mem.Allocator.Error!*Environment {
    self.maybeCollect();
    const environment = try self.gpa.create(Environment);
    environment.* = .{};
    self.linkEnvironment(environment);
    return environment;
}

fn linkEnvironment(self: *Heap, environment: *Environment) void {
    self.live_objects += 1;
    environment.next = self.live_environments;
    if (self.live_environments) |first| first.previous = environment;
    self.live_environments = environment;
}

fn unlinkEnvironment(self: *Heap, environment: *Environment) void {
    self.live_objects -= 1;
    if (environment.previous) |previous| {
        previous.next = environment.next;
    } else {
        self.live_environments = environment.next;
    }
    if (environment.next) |next| next.previous = environment.previous;
}

/// Releases everything the environment's names hold and takes it out of the
/// live list, leaving the table allocated for whoever recycles it. Only for an
/// environment nothing else holds.
pub fn recycleEnvironment(self: *Heap, environment: *Environment) void {
    std.debug.assert(environment.references == 1);
    self.releaseBindings(environment);
    self.unlinkEnvironment(environment);
    environment.previous = null;
    environment.next = null;
}

/// Puts a recycled environment back in use.
pub fn reuseEnvironment(self: *Heap, environment: *Environment) void {
    environment.references = 1;
    environment.marked = false;
    environment.bindings.clearRetainingCapacity();
    self.linkEnvironment(environment);
}

fn releaseBindings(self: *Heap, environment: *Environment) void {
    var bindings = environment.bindings.valueIterator();
    while (bindings.next()) |binding| {
        if (binding.value) |value| self.release(value);
    }
    environment.bindings.clearRetainingCapacity();
}

/// A closure over `captured`, which it takes ownership of and must come from
/// `gpa`. Each captured environment gains a holder.
pub fn createClosure(
    self: *Heap,
    function: Closure.Function,
    captured: []*Environment,
) std.mem.Allocator.Error!*Closure {
    self.maybeCollect();
    const closure = self.gpa.create(Closure) catch |err| {
        self.gpa.free(captured);
        return err;
    };
    self.live_objects += 1;
    closure.* = .{ .function = function, .captured = captured };
    for (captured) |environment| environment.references += 1;
    closure.next = self.live_closures;
    if (self.live_closures) |first| first.previous = closure;
    self.live_closures = closure;
    return closure;
}

/// A string that owns `bytes`, which must come from `gpa` and be valid UTF-8,
/// with one holder, the caller. On failure `bytes` is freed.
pub fn createText(self: *Heap, bytes: []const u8) std.mem.Allocator.Error!*Text {
    self.maybeCollect();
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
    self.maybeCollect();
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
    self.live_objects += 1;
    text.next = self.live_texts;
    if (self.live_texts) |first| first.previous = text;
    self.live_texts = text;
}

fn destroyText(self: *Heap, text: *Text) void {
    self.live_objects -= 1;
    if (!text.literal) self.gpa.free(text.bytes);
    self.gpa.destroy(text);
}

/// An empty list of `element` values with one holder, the caller.
pub fn createList(self: *Heap, element: Value.Kind, capacity: usize) std.mem.Allocator.Error!*List {
    self.maybeCollect();
    const list = try self.gpa.create(List);
    list.* = .{ .element = element };
    list.items.ensureTotalCapacity(self.gpa, capacity) catch |err| {
        self.gpa.destroy(list);
        return err;
    };
    self.live_objects += 1;
    list.next = self.live;
    if (self.live) |first| first.previous = list;
    self.live = list;
    return list;
}

/// Records a new holder of `value`, and returns it for convenience.
pub fn retain(value: Value) Value {
    switch (value.data) {
        .list => |list| list.references += 1,
        .closure => |closure| closure.references += 1,
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
    if (value.data == .closure) {
        const closure = value.data.closure;
        closure.references -= 1;
        if (closure.references > 0) return;
        for (closure.captured) |environment| self.releaseEnvironment(environment);
        self.unlinkClosure(closure);
        self.gpa.free(closure.captured);
        self.gpa.destroy(closure);
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

fn unlinkClosure(self: *Heap, closure: *Closure) void {
    self.live_objects -= 1;
    if (closure.previous) |previous| {
        previous.next = closure.next;
    } else {
        self.live_closures = closure.next;
    }
    if (closure.next) |next| next.previous = closure.previous;
}

/// Records that one holder of the environment is gone, freeing it when it was
/// the last.
pub fn releaseEnvironment(self: *Heap, environment: *Environment) void {
    environment.references -= 1;
    if (environment.references > 0) return;
    self.releaseBindings(environment);
    self.unlinkEnvironment(environment);
    environment.bindings.deinit(self.gpa);
    self.gpa.destroy(environment);
}

// Section 19.5's collector.

/// One managed object, for the collector's worklist.
const Object = union(enum) {
    list: *List,
    text: *Text,
    environment: *Environment,
    closure: *Closure,

    fn of(value: Value) ?Object {
        return switch (value.data) {
            .list => |list| .{ .list = list },
            .string => |text| .{ .text = text },
            .closure => |closure| .{ .closure = closure },
            .nothing, .bool, .int, .float => null,
        };
    }
};

/// Collects when enough objects are live, which is section 19.5's "predictable
/// allocation thresholds". Called before allocating rather than after, so no
/// half-built object is ever exposed to a trace.
fn maybeCollect(self: *Heap) void {
    if (self.live_objects < self.collect_after) return;
    self.collect();
}

/// Section 19.5's nonmoving, stop-the-world mark-and-sweep collection, which
/// exists to reclaim what reference counting cannot: a closure and the
/// environment it captured hold each other, and storing a block in a local is
/// enough to make that happen.
///
/// The roots are computed from the counts rather than declared. Every holder of
/// an object retains it — that is the invariant this file is built on, and the
/// counts may be too high but never too low — so an object held from outside
/// the heap has a count that nothing inside the heap accounts for. Tallying how
/// many references come from other managed objects and comparing against the
/// count therefore finds exactly the objects something outside is holding:
/// module variables, the scope stack, and every `Value` in flight in a Zig
/// local.
///
/// This departs from section 19.5's explicit root API, and the reason is the
/// failure mode. An explicit root API means every temporary the evaluator holds
/// across an allocation must be registered, and one missed registration frees
/// an object still in use. Deriving the roots from counts instead cannot do
/// that: a count that is too high keeps a dead object alive, so the worst
/// mistake is a leak, which is what this collector exists to reduce rather than
/// something it can turn into corruption. The rule section 19.5 is protecting —
/// that no hidden pointer silently keeps an object alive — still holds, because
/// retaining is what makes a pointer a holder and nothing may hold without it.
pub fn collect(self: *Heap) void {
    self.resetMarks();
    self.countInternalReferences();
    // Tracing needs memory it may not get. Nothing has been freed at that
    // point, so giving up leaves a correct heap and simply collects nothing.
    if (!self.markReachable()) return;
    self.sweep();
    self.collect_after = @max(minimum_threshold, self.live_objects * 2);
}

fn resetMarks(self: *Heap) void {
    var lists = self.live;
    while (lists) |list| : (lists = list.next) {
        list.marked = false;
        list.internal = 0;
    }
    var texts = self.live_texts;
    while (texts) |text| : (texts = text.next) {
        text.marked = false;
        text.internal = 0;
    }
    var environments = self.live_environments;
    while (environments) |environment| : (environments = environment.next) {
        environment.marked = false;
        environment.internal = 0;
    }
    var closures = self.live_closures;
    while (closures) |closure| : (closures = closure.next) {
        closure.marked = false;
        closure.internal = 0;
    }
}

/// Tallies, for each object, how many of its holders are themselves managed
/// objects. Whatever the count has beyond that came from outside the heap.
fn countInternalReferences(self: *Heap) void {
    var lists = self.live;
    while (lists) |list| : (lists = list.next) {
        for (list.items.items) |item| bumpInternal(item);
    }
    var environments = self.live_environments;
    while (environments) |environment| : (environments = environment.next) {
        var bindings = environment.bindings.valueIterator();
        while (bindings.next()) |binding| {
            if (binding.value) |value| bumpInternal(value);
        }
    }
    var closures = self.live_closures;
    while (closures) |closure| : (closures = closure.next) {
        for (closure.captured) |environment| environment.internal += 1;
    }
}

fn bumpInternal(value: Value) void {
    const object = Object.of(value) orelse return;
    switch (object) {
        // A literal string is never counted, so counting holders of one would
        // only make it look like garbage.
        .text => |text| if (!text.literal) {
            text.internal += 1;
        },
        inline else => |other| other.internal += 1,
    }
}

/// Marks everything reachable from an object something outside the heap holds.
/// Returns false if the worklist could not grow, in which case nothing may be
/// swept.
fn markReachable(self: *Heap) bool {
    self.work.clearRetainingCapacity();

    var lists = self.live;
    while (lists) |list| : (lists = list.next) {
        if (list.references > list.internal and !self.push(.{ .list = list })) return false;
    }
    var texts = self.live_texts;
    while (texts) |text| : (texts = text.next) {
        // A literal's text belongs to the syntax tree for the whole run, and
        // the interpreter's cache of them is not a counted holder.
        if (text.literal or text.references > text.internal) text.marked = true;
    }
    var environments = self.live_environments;
    while (environments) |environment| : (environments = environment.next) {
        if (environment.references > environment.internal and
            !self.push(.{ .environment = environment })) return false;
    }
    var closures = self.live_closures;
    while (closures) |closure| : (closures = closure.next) {
        if (closure.references > closure.internal and !self.push(.{ .closure = closure })) return false;
    }

    while (self.work.pop()) |object| {
        switch (object) {
            .text => {},
            .list => |list| for (list.items.items) |item| {
                if (!self.reach(item)) return false;
            },
            .environment => |environment| {
                var bindings = environment.bindings.valueIterator();
                while (bindings.next()) |binding| {
                    if (binding.value) |value| {
                        if (!self.reach(value)) return false;
                    }
                }
            },
            .closure => |closure| for (closure.captured) |environment| {
                if (!environment.marked and !self.push(.{ .environment = environment })) return false;
            },
        }
    }
    return true;
}

fn reach(self: *Heap, value: Value) bool {
    const object = Object.of(value) orelse return true;
    return switch (object) {
        .text => |text| blk: {
            text.marked = true;
            break :blk true;
        },
        inline else => |other| other.marked or self.push(object),
    };
}

/// Marks the object and queues what it refers to. False means out of memory.
fn push(self: *Heap, object: Object) bool {
    switch (object) {
        inline else => |target| target.marked = true,
    }
    self.work.append(self.gpa, object) catch return false;
    return true;
}

/// Frees every object nothing reachable holds.
///
/// Counts inside the garbage no longer matter, but counts on survivors do: a
/// dead cycle can hold a live string, and dropping the cycle without that
/// reference would keep the string forever.
fn sweep(self: *Heap) void {
    var lists = self.live;
    while (lists) |list| : (lists = list.next) {
        if (!list.marked) {
            for (list.items.items) |item| dropReference(item);
        }
    }
    var environments = self.live_environments;
    while (environments) |environment| : (environments = environment.next) {
        if (!environment.marked) {
            var bindings = environment.bindings.valueIterator();
            while (bindings.next()) |binding| {
                if (binding.value) |value| dropReference(value);
            }
        }
    }
    var closures = self.live_closures;
    while (closures) |closure| : (closures = closure.next) {
        if (!closure.marked) {
            for (closure.captured) |environment| environment.references -= 1;
        }
    }

    var next_list = self.live;
    while (next_list) |list| {
        next_list = list.next;
        if (list.marked) continue;
        self.unlink(list);
        list.items.deinit(self.gpa);
        self.gpa.destroy(list);
    }
    var next_closure = self.live_closures;
    while (next_closure) |closure| {
        next_closure = closure.next;
        if (closure.marked) continue;
        self.unlinkClosure(closure);
        self.gpa.free(closure.captured);
        self.gpa.destroy(closure);
    }
    var next_environment = self.live_environments;
    while (next_environment) |environment| {
        next_environment = environment.next;
        if (environment.marked) continue;
        self.unlinkEnvironment(environment);
        environment.bindings.deinit(self.gpa);
        self.gpa.destroy(environment);
    }
    var next_text = self.live_texts;
    while (next_text) |text| {
        next_text = text.next;
        if (text.marked) continue;
        if (text.previous) |previous| previous.next = text.next else self.live_texts = text.next;
        if (text.next) |following| following.previous = text.previous;
        self.destroyText(text);
    }
}

/// Removes one reference held by an object being swept, without the cascading
/// free `release` would do: everything unmarked is freed by the sweep itself.
fn dropReference(value: Value) void {
    const object = Object.of(value) orelse return;
    switch (object) {
        .text => |text| if (!text.literal) {
            text.references -= 1;
        },
        inline else => |other| other.references -= 1,
    }
}

fn unlink(self: *Heap, list: *List) void {
    self.live_objects -= 1;
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

test "a cycle is reclaimed, which counting alone cannot do" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    // A closure that captured the environment its own name lives in, which is
    // what `const block = { ... }` builds.
    const environment = try heap.createEnvironment();
    const closure = try heap.createClosure(.{ .named = "block" }, try testing.allocator.dupe(*Environment, &.{environment}));
    try environment.bindings.put(testing.allocator, "block", .{
        .kind = .closure,
        .value = .{ .data = .{ .closure = closure } },
    });

    // Nothing outside the heap holds either now, and neither count is zero.
    heap.releaseEnvironment(environment);
    try testing.expectEqual(@as(u32, 1), environment.references);
    try testing.expectEqual(@as(u32, 1), closure.references);

    heap.collect();
    try testing.expect(heap.live_environments == null);
    try testing.expect(heap.live_closures == null);
    try testing.expectEqual(@as(usize, 0), heap.live_objects);
}

test "collection keeps everything something outside the heap holds" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    // A list held only by this Zig local, which no root API was told about.
    const held = try listOfInts(&heap, &.{ 1, 2, 3 });
    const nested = try listOfInts(&heap, &.{4});
    try held.data.list.items.append(testing.allocator, nested);

    heap.collect();

    try testing.expectEqual(@as(usize, 2), heap.live_objects);
    try testing.expectEqual(@as(usize, 4), held.data.list.items.items.len);
    try testing.expectEqual(@as(i64, 4), nested.data.list.items.items[0].data.int);

    heap.release(held);
}

test "a dead cycle releases what it held, so survivors are not kept by it" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const survivor = try heap.copyText("kept");
    defer heap.release(survivor);

    {
        const environment = try heap.createEnvironment();
        const closure = try heap.createClosure(.{ .named = "block" }, try testing.allocator.dupe(*Environment, &.{environment}));
        try environment.bindings.put(testing.allocator, "block", .{
            .kind = .closure,
            .value = .{ .data = .{ .closure = closure } },
        });
        // The cycle also holds the string.
        try environment.bindings.put(testing.allocator, "text", .{
            .kind = .string,
            .value = retain(survivor),
        });
        heap.releaseEnvironment(environment);
    }

    try testing.expectEqual(@as(u32, 2), survivor.data.string.references);
    heap.collect();
    // The cycle is gone and its hold on the string went with it.
    try testing.expectEqual(@as(u32, 1), survivor.data.string.references);
    try testing.expectEqual(@as(usize, 1), heap.live_objects);
}

test "a literal's text is never swept, however it is held" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    // Literals are not counted, so they can only be kept by being roots.
    const literal = try heap.literalText("hello");
    heap.collect();
    try testing.expect(heap.live_texts == literal);
    try testing.expectEqualStrings("hello", literal.bytes);
}
