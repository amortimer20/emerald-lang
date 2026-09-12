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
//! rare. Nothing is read or written after death and nothing is freed twice; the
//! memory is simply not reclaimed until the run ends, when `deinit` frees every
//! object whatever its count says. Section 19.5's mark-and-sweep collector is
//! what reclaims cycles during a run, and `live`, `live_texts`,
//! `live_environments`, and `live_closures` are exactly the object lists it
//! walks.

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
    self.* = undefined;
}

/// An empty environment with one holder, the caller.
pub fn createEnvironment(self: *Heap) std.mem.Allocator.Error!*Environment {
    const environment = try self.gpa.create(Environment);
    environment.* = .{};
    self.linkEnvironment(environment);
    return environment;
}

fn linkEnvironment(self: *Heap, environment: *Environment) void {
    environment.next = self.live_environments;
    if (self.live_environments) |first| first.previous = environment;
    self.live_environments = environment;
}

fn unlinkEnvironment(self: *Heap, environment: *Environment) void {
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
    const closure = self.gpa.create(Closure) catch |err| {
        self.gpa.free(captured);
        return err;
    };
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
        if (closure.previous) |previous| {
            previous.next = closure.next;
        } else {
            self.live_closures = closure.next;
        }
        if (closure.next) |next| next.previous = closure.previous;
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
