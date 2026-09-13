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
//! the other half: `collect` walks `live`, `live_tuples`, `live_maps`,
//! `live_texts`, `live_environments`, `live_closures`, and `live_structs`, and
//! frees whatever nothing outside the heap can reach.
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

/// Section 8.2's `(String, Int)`.
///
/// Counted like a list, but never copied: section 8.2 gives no way to assign to
/// a position, so a tuple cannot change once it is built and nothing can
/// observe it being shared. That is also why there is no copy-on-write here.
pub const Tuple = struct {
    references: u32 = 1,
    /// One value per position, at least two, fixed for the tuple's life.
    items: []Value,
    /// The kind each position holds, for section 4.4's widening, as a list's
    /// `element` does.
    kinds: []Value.Kind,
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live_tuples`.
    previous: ?*Tuple = null,
    next: ?*Tuple = null,
};

/// One instance of a user-defined value type. The descriptor belongs to the
/// interpreter arena; this object owns one value for each stored field.
pub const StructValue = struct {
    references: u32 = 1,
    descriptor: *const Value.StructType,
    fields: []Value,
    marked: bool = false,
    internal: u32 = 0,
    previous: ?*StructValue = null,
    next: ?*StructValue = null,
};

/// Section 8.2's dictionary and set, which are one structure: a set is a
/// dictionary that stores no values.
///
/// Section 8.4 requires insertion order to be preserved for iteration and
/// printing, so the entries are an array in the order they were added and the
/// hash table holds indices into it. Replacing a value keeps its position;
/// removing and reinserting a key moves it to the end, which falls out of
/// appending.
///
/// Each entry keeps the hash it was stored under. Hashing a string means
/// normalizing it (9.2), which is the expensive part, so keeping the hash makes
/// rebuilding the table after a removal cheap and lets a lookup rule out most
/// entries before it compares anything.
pub const Map = struct {
    references: u32 = 1,
    entries: std.ArrayList(Entry) = .empty,
    /// Open addressing: each slot holds an index into `entries`, or `vacant`.
    /// Always a power of two, so the mask is the size minus one.
    slots: []u32 = &.{},
    /// The kind of key and of value, for section 4.4's widening, as a list's
    /// `element` is. A set's `value` kind is `.nothing`.
    key_kind: Value.Kind,
    value_kind: Value.Kind,
    /// Whether this is section 8.2's `{T}` rather than `[K: V]`. They differ
    /// only in what they store and how they print.
    is_set: bool,
    /// Collector bookkeeping; see `collect`.
    marked: bool = false,
    internal: u32 = 0,
    /// Neighbors in `live_maps`.
    previous: ?*Map = null,
    next: ?*Map = null,

    pub const Entry = struct {
        hash: u64,
        key: Value,
        /// `Value.nothing` for a set, which stores no values.
        value: Value,
    };

    /// No entry. `entries` can never reach this many, because every entry is at
    /// least a key and the heap would be exhausted first.
    pub const vacant: u32 = std.math.maxInt(u32);

    pub fn count(self: *const Map) usize {
        return self.entries.items.len;
    }
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
    /// Null until section 4.1's definite assignment says otherwise, and while
    /// a method that changes it has the value (see `changing`).
    value: ?Value,
    /// The method that has taken this binding's value to change it, while that
    /// call runs. Anything else reaching the binding meanwhile is an error
    /// rather than a look at a value that is half changed.
    changing: ?[]const u8 = null,
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
    /// The file it was written in, which decides what its bare module-level
    /// names mean wherever it is eventually called (14.1).
    file: u32 = 0,
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
/// Every tuple not yet freed.
live_tuples: ?*Tuple = null,
/// Every dictionary and set not yet freed.
live_maps: ?*Map = null,
/// Every user-defined struct instance not yet freed.
live_structs: ?*StructValue = null,
/// How many objects are in the managed-object lists.
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
    var tuples = self.live_tuples;
    while (tuples) |tuple| {
        tuples = tuple.next;
        self.destroyTuple(tuple);
    }
    var maps = self.live_maps;
    while (maps) |map| {
        maps = map.next;
        self.destroyMap(map);
    }
    var structs = self.live_structs;
    while (structs) |instance| {
        structs = instance.next;
        self.destroyStruct(instance);
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
    file: u32,
) std.mem.Allocator.Error!*Closure {
    self.maybeCollect();
    const closure = self.gpa.create(Closure) catch |err| {
        self.gpa.free(captured);
        return err;
    };
    self.live_objects += 1;
    closure.* = .{ .function = function, .captured = captured, .file = file };
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

/// A tuple holding `items`, whose memory it takes over, with one holder, the
/// caller. `kinds` is taken over too.
pub fn createTuple(self: *Heap, items: []Value, kinds: []Value.Kind) std.mem.Allocator.Error!*Tuple {
    self.maybeCollect();
    const tuple = self.gpa.create(Tuple) catch |err| {
        self.gpa.free(items);
        self.gpa.free(kinds);
        return err;
    };
    self.live_objects += 1;
    tuple.* = .{ .items = items, .kinds = kinds };
    tuple.next = self.live_tuples;
    if (self.live_tuples) |first| first.previous = tuple;
    self.live_tuples = tuple;
    return tuple;
}

/// A user-defined struct holding `fields`, whose memory and values it takes
/// over, with one holder in the caller.
pub fn createStruct(
    self: *Heap,
    descriptor: *const Value.StructType,
    fields: []Value,
) std.mem.Allocator.Error!*StructValue {
    self.maybeCollect();
    const instance = self.gpa.create(StructValue) catch |err| {
        for (fields) |field| self.release(field);
        self.gpa.free(fields);
        return err;
    };
    self.live_objects += 1;
    instance.* = .{ .descriptor = descriptor, .fields = fields };
    instance.next = self.live_structs;
    if (self.live_structs) |first| first.previous = instance;
    self.live_structs = instance;
    return instance;
}

fn destroyStruct(self: *Heap, instance: *StructValue) void {
    self.gpa.free(instance.fields);
    self.gpa.destroy(instance);
}

fn unlinkStruct(self: *Heap, instance: *StructValue) void {
    self.live_objects -= 1;
    if (instance.previous) |previous| previous.next = instance.next else self.live_structs = instance.next;
    if (instance.next) |next| next.previous = instance.previous;
}

/// Makes the struct instance in `slot` safe to change in place: when anything
/// else holds it, the slot gets a copy of its own fields first. This is the
/// same copy-on-write `unique` and `uniqueMap` already do, which is what
/// keeps section 10.1's value semantics true once fields can be assigned.
pub fn uniqueStruct(self: *Heap, slot: *Value) std.mem.Allocator.Error!*StructValue {
    const shared = slot.data.struct_value;
    if (shared.references == 1) return shared;

    const fields = try self.gpa.alloc(Value, shared.fields.len);
    for (shared.fields, fields) |field, *copied| copied.* = retain(field);
    const copy = try self.createStruct(shared.descriptor, fields);

    shared.references -= 1; // the slot no longer holds it, and someone else does
    slot.* = .{ .data = .{ .struct_value = copy } };
    return copy;
}

fn destroyTuple(self: *Heap, tuple: *Tuple) void {
    self.gpa.free(tuple.items);
    self.gpa.free(tuple.kinds);
    self.gpa.destroy(tuple);
}

fn unlinkTuple(self: *Heap, tuple: *Tuple) void {
    self.live_objects -= 1;
    if (tuple.previous) |previous| previous.next = tuple.next else self.live_tuples = tuple.next;
    if (tuple.next) |next| next.previous = tuple.previous;
}

/// An empty dictionary or set with one holder, the caller.
pub fn createMap(
    self: *Heap,
    key_kind: Value.Kind,
    value_kind: Value.Kind,
    is_set: bool,
) std.mem.Allocator.Error!*Map {
    self.maybeCollect();
    const map = try self.gpa.create(Map);
    self.live_objects += 1;
    map.* = .{ .key_kind = key_kind, .value_kind = value_kind, .is_set = is_set };
    map.next = self.live_maps;
    if (self.live_maps) |first| first.previous = map;
    self.live_maps = map;
    return map;
}

fn destroyMap(self: *Heap, map: *Map) void {
    map.entries.deinit(self.gpa);
    self.gpa.free(map.slots);
    self.gpa.destroy(map);
}

fn unlinkMap(self: *Heap, map: *Map) void {
    self.live_objects -= 1;
    if (map.previous) |previous| previous.next = map.next else self.live_maps = map.next;
    if (map.next) |next| next.previous = map.previous;
}

/// Makes the map in `slot` safe to change in place, copying it first when
/// anything else holds it. The dictionary half of section 8.1's value
/// semantics, and the same copy-on-write rule `unique` applies to a list.
pub fn uniqueMap(self: *Heap, slot: *Value) std.mem.Allocator.Error!*Map {
    const shared = slot.data.map;
    if (shared.references == 1) return shared;

    const copy = try self.createMap(shared.key_kind, shared.value_kind, shared.is_set);
    errdefer {
        self.unlinkMap(copy);
        self.destroyMap(copy);
    }
    try copy.entries.appendSlice(self.gpa, shared.entries.items);
    for (copy.entries.items) |entry| {
        _ = retain(entry.key);
        _ = retain(entry.value);
    }
    copy.slots = try self.gpa.dupe(u32, shared.slots);

    shared.references -= 1; // the slot no longer holds it, and someone else does
    slot.* = .{ .data = .{ .map = copy } };
    return copy;
}

/// Stores `key` with `value`, taking over one holder of each. An existing key
/// keeps its position and takes the new value, which is section 8.4's rule.
pub fn put(self: *Heap, map: *Map, hash: u64, key: Value, value: Value) std.mem.Allocator.Error!void {
    switch (try self.locate(map, hash, key)) {
        .entry => |index| {
            const entry = &map.entries.items[index];
            // The key that is already there stays, so the new one is dropped.
            self.release(key);
            self.release(entry.value);
            entry.value = value;
        },
        .vacancy => {
            // Grown before the entry goes in, so the slot found above is still
            // the right one when it does not grow.
            if (try self.growSlots(map)) {
                return self.putKnownAbsent(map, hash, key, value);
            }
            map.entries.append(self.gpa, .{ .hash = hash, .key = key, .value = value }) catch |err| {
                self.release(key);
                self.release(value);
                return err;
            };
            self.claim(map, hash, @intCast(map.entries.items.len - 1));
        },
    }
}

/// The same, when the key is known not to be present because the table has just
/// been rebuilt underneath it.
fn putKnownAbsent(self: *Heap, map: *Map, hash: u64, key: Value, value: Value) std.mem.Allocator.Error!void {
    map.entries.append(self.gpa, .{ .hash = hash, .key = key, .value = value }) catch |err| {
        self.release(key);
        self.release(value);
        return err;
    };
    self.claim(map, hash, @intCast(map.entries.items.len - 1));
}

/// Puts `index` in the first free slot its hash reaches. The table always has
/// room, because `growSlots` runs first.
fn claim(_: *Heap, map: *Map, hash: u64, index: u32) void {
    const mask = map.slots.len - 1;
    var at = @as(usize, @truncate(hash)) & mask;
    while (map.slots[at] != Map.vacant) at = (at + 1) & mask;
    map.slots[at] = index;
}

/// Keeps the table under three-quarters full, which is what keeps the linear
/// probe above short. Returns whether it rebuilt, since that invalidates any
/// vacancy found before it.
fn growSlots(self: *Heap, map: *Map) std.mem.Allocator.Error!bool {
    const needed = map.entries.items.len + 1;
    if (map.slots.len != 0 and needed * 4 <= map.slots.len * 3) return false;

    var size: usize = 8;
    while (needed * 4 > size * 3) size *= 2;
    try self.reindex(map, size);
    return true;
}

/// Rebuilds the table at `size` slots from the entries, which is also how a
/// removal repairs the indices it shifted.
fn reindex(self: *Heap, map: *Map, size: usize) std.mem.Allocator.Error!void {
    const slots = try self.gpa.alloc(u32, size);
    @memset(slots, Map.vacant);
    self.gpa.free(map.slots);
    map.slots = slots;
    for (map.entries.items, 0..) |entry, index| self.claim(map, entry.hash, @intCast(index));
}

/// Section 8.5's `remove`. Returns the value that was stored, or null when the
/// key was not there. The caller takes over one holder of the returned value.
pub fn removeKey(self: *Heap, map: *Map, hash: u64, key: Value) std.mem.Allocator.Error!?Value {
    const index = switch (try self.locate(map, hash, key)) {
        .entry => |at| at,
        .vacancy => return null,
    };

    const entry = map.entries.orderedRemove(index);
    self.release(entry.key);

    // Every index above the removed one shifted, so the table is rebuilt. It
    // costs a pass over the entries, and it needs no rehashing because each
    // entry carries the hash it was stored under.
    try self.reindex(map, map.slots.len);
    return entry.value;
}

/// The entry with this key, or null. A free function because `Value.equals`
/// compares two maps and has no heap to ask.
pub fn lookupIn(
    gpa: std.mem.Allocator,
    map: *const Map,
    hash: u64,
    key: Value,
) std.mem.Allocator.Error!?Map.Entry {
    if (map.slots.len == 0) return null;
    const mask = map.slots.len - 1;
    var at = @as(usize, @truncate(hash)) & mask;
    while (true) {
        const index = map.slots[at];
        if (index == Map.vacant) return null;
        const entry = map.entries.items[index];
        if (entry.hash == hash and try Value.equals(gpa, entry.key, key)) return entry;
        at = (at + 1) & mask;
    }
}

/// Where a key belongs: the entry holding it, or the slot a new one would take.
pub const Found = union(enum) {
    /// The index into `entries` of the entry with this key.
    entry: usize,
    /// The index into `slots` where a new entry's index would go.
    vacancy: usize,
};

/// Section 8.3's lookup. Equality is Emerald's `==`, which for strings
/// normalizes (9.2) and so may allocate, which is why this can fail.
pub fn locate(self: *Heap, map: *const Map, hash: u64, key: Value) std.mem.Allocator.Error!Found {
    if (map.slots.len == 0) return .{ .vacancy = 0 };

    const mask = map.slots.len - 1;
    var at = @as(usize, @truncate(hash)) & mask;
    while (true) {
        const index = map.slots[at];
        if (index == Map.vacant) return .{ .vacancy = at };
        const entry = map.entries.items[index];
        // The stored hash rules out almost every entry without comparing, which
        // matters because comparing two strings can mean normalizing them.
        if (entry.hash == hash and try Value.equals(self.gpa, entry.key, key)) {
            return .{ .entry = index };
        }
        at = (at + 1) & mask;
    }
}

/// Records a new holder of `value`, and returns it for convenience.
pub fn retain(value: Value) Value {
    switch (value.data) {
        .list => |list| list.references += 1,
        .tuple => |tuple| tuple.references += 1,
        .map => |map| map.references += 1,
        .closure => |closure| closure.references += 1,
        .struct_value => |instance| instance.references += 1,
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
    if (value.data == .tuple) {
        const tuple = value.data.tuple;
        tuple.references -= 1;
        if (tuple.references > 0) return;
        for (tuple.items) |item| self.release(item);
        self.unlinkTuple(tuple);
        self.destroyTuple(tuple);
        return;
    }
    if (value.data == .map) {
        const map = value.data.map;
        map.references -= 1;
        if (map.references > 0) return;
        for (map.entries.items) |entry| {
            self.release(entry.key);
            self.release(entry.value);
        }
        self.unlinkMap(map);
        self.destroyMap(map);
        return;
    }
    if (value.data == .struct_value) {
        const instance = value.data.struct_value;
        instance.references -= 1;
        if (instance.references > 0) return;
        for (instance.fields) |field| self.release(field);
        self.unlinkStruct(instance);
        self.destroyStruct(instance);
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
    tuple: *Tuple,
    map: *Map,
    text: *Text,
    environment: *Environment,
    closure: *Closure,
    struct_value: *StructValue,

    fn of(value: Value) ?Object {
        return switch (value.data) {
            .list => |list| .{ .list = list },
            .tuple => |tuple| .{ .tuple = tuple },
            .map => |map| .{ .map = map },
            .string => |text| .{ .text = text },
            .closure => |closure| .{ .closure = closure },
            .struct_value => |instance| .{ .struct_value = instance },
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
    var tuples = self.live_tuples;
    while (tuples) |tuple| : (tuples = tuple.next) {
        tuple.marked = false;
        tuple.internal = 0;
    }
    var maps = self.live_maps;
    while (maps) |map| : (maps = map.next) {
        map.marked = false;
        map.internal = 0;
    }
    var structs = self.live_structs;
    while (structs) |instance| : (structs = instance.next) {
        instance.marked = false;
        instance.internal = 0;
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
    var tuples = self.live_tuples;
    while (tuples) |tuple| : (tuples = tuple.next) {
        for (tuple.items) |item| bumpInternal(item);
    }
    var maps = self.live_maps;
    while (maps) |map| : (maps = map.next) {
        for (map.entries.items) |entry| {
            bumpInternal(entry.key);
            bumpInternal(entry.value);
        }
    }
    var structs = self.live_structs;
    while (structs) |instance| : (structs = instance.next) {
        for (instance.fields) |field| bumpInternal(field);
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
    var tuples = self.live_tuples;
    while (tuples) |tuple| : (tuples = tuple.next) {
        if (tuple.references > tuple.internal and !self.push(.{ .tuple = tuple })) return false;
    }
    var maps = self.live_maps;
    while (maps) |map| : (maps = map.next) {
        if (map.references > map.internal and !self.push(.{ .map = map })) return false;
    }
    var structs = self.live_structs;
    while (structs) |instance| : (structs = instance.next) {
        if (instance.references > instance.internal and !self.push(.{ .struct_value = instance })) return false;
    }

    while (self.work.pop()) |object| {
        switch (object) {
            .text => {},
            .list => |list| for (list.items.items) |item| {
                if (!self.reach(item)) return false;
            },
            .tuple => |tuple| for (tuple.items) |item| {
                if (!self.reach(item)) return false;
            },
            .map => |map| for (map.entries.items) |entry| {
                if (!self.reach(entry.key)) return false;
                if (!self.reach(entry.value)) return false;
            },
            .struct_value => |instance| for (instance.fields) |field| {
                if (!self.reach(field)) return false;
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
    var tuples = self.live_tuples;
    while (tuples) |tuple| : (tuples = tuple.next) {
        if (!tuple.marked) {
            for (tuple.items) |item| dropReference(item);
        }
    }
    var maps = self.live_maps;
    while (maps) |map| : (maps = map.next) {
        if (!map.marked) {
            for (map.entries.items) |entry| {
                dropReference(entry.key);
                dropReference(entry.value);
            }
        }
    }
    var structs = self.live_structs;
    while (structs) |instance| : (structs = instance.next) {
        if (!instance.marked) {
            for (instance.fields) |field| dropReference(field);
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
    var next_map = self.live_maps;
    while (next_map) |map| {
        next_map = map.next;
        if (map.marked) continue;
        self.unlinkMap(map);
        self.destroyMap(map);
    }
    var next_tuple = self.live_tuples;
    while (next_tuple) |tuple| {
        next_tuple = tuple.next;
        if (tuple.marked) continue;
        self.unlinkTuple(tuple);
        self.destroyTuple(tuple);
    }
    var next_struct = self.live_structs;
    while (next_struct) |instance| {
        next_struct = instance.next;
        if (instance.marked) continue;
        self.unlinkStruct(instance);
        self.destroyStruct(instance);
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

fn tupleOfInts(heap: *Heap, values: []const i64) !Value {
    const items = try testing.allocator.alloc(Value, values.len);
    const kinds = try testing.allocator.alloc(Value.Kind, values.len);
    for (values, items, kinds) |value, *item, *item_kind| {
        item.* = .initInt(value);
        item_kind.* = .int;
    }
    return .{ .data = .{ .tuple = try heap.createTuple(items, kinds) } };
}

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

test "releasing the last holder of a tuple frees it and what it holds" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const held = try listOfInts(&heap, &.{1});
    const items = try testing.allocator.alloc(Value, 2);
    const kinds = try testing.allocator.alloc(Value.Kind, 2);
    items[0] = .initInt(7);
    items[1] = held;
    kinds[0] = .int;
    kinds[1] = .list;
    const tuple: Value = .{ .data = .{ .tuple = try heap.createTuple(items, kinds) } };

    heap.release(tuple);
    try testing.expect(heap.live_tuples == null);
    // The list the tuple held went with it: the tuple was its only holder.
    try testing.expect(heap.live == null);
}

test "a tuple is shared rather than copied, because it cannot change" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const original = try tupleOfInts(&heap, &.{ 1, 2 });
    const copy = retain(original);
    try testing.expectEqual(original.data.tuple, copy.data.tuple);
    try testing.expectEqual(@as(u32, 2), original.data.tuple.references);

    heap.release(copy);
    try testing.expect(heap.live_tuples != null);
    heap.release(original);
    try testing.expect(heap.live_tuples == null);
}

test "releasing the last holder of a struct frees it and its fields" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const metadata = [_]Value.StructType.Field{.{ .name = "values", .kind = .list }};
    const descriptor: Value.StructType = .{ .name = "Bag", .display_name = "Bag", .fields = &metadata };
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = try listOfInts(&heap, &.{1});
    const instance: Value = .{ .data = .{ .struct_value = try heap.createStruct(&descriptor, fields) } };

    heap.release(instance);
    try testing.expect(heap.live_structs == null);
    try testing.expect(heap.live == null);
}

test "uniqueStruct copies a shared instance before it changes" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const metadata = [_]Value.StructType.Field{.{ .name = "x", .kind = .int }};
    const descriptor: Value.StructType = .{ .name = "Box", .display_name = "Box", .fields = &metadata };
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = .initInt(1);

    var a: Value = .{ .data = .{ .struct_value = try heap.createStruct(&descriptor, fields) } };
    const b = retain(a); // a second holder, as `var b = a` produces

    const copy = try heap.uniqueStruct(&a);
    copy.fields[0] = .initInt(2);

    // `b` still sees the original instance untouched by the change made
    // through `a`, which is section 10.1's value semantics.
    try testing.expectEqual(@as(i64, 1), b.data.struct_value.fields[0].data.int);
    try testing.expectEqual(@as(i64, 2), a.data.struct_value.fields[0].data.int);
    try testing.expect(a.data.struct_value != b.data.struct_value);

    heap.release(a);
    heap.release(b);
    try testing.expect(heap.live_structs == null);
}

test "the collector reclaims a cycle through a struct" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const environment = try heap.createEnvironment();
    const closure = try heap.createClosure(
        .{ .named = "block" },
        try testing.allocator.dupe(*Environment, &.{environment}),
        0,
    );
    heap.releaseEnvironment(environment); // the closure holds it now

    const metadata = [_]Value.StructType.Field{.{ .name = "action", .kind = .closure }};
    const descriptor: Value.StructType = .{ .name = "Task", .display_name = "Task", .fields = &metadata };
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = .{ .data = .{ .closure = closure } };
    const instance = try heap.createStruct(&descriptor, fields);

    try environment.bindings.put(testing.allocator, "task", .{
        .kind = .struct_value,
        .value = .{ .data = .{ .struct_value = instance } },
    });
    instance.references += 1; // the environment holds it
    instance.references -= 1; // and nothing outside the heap does

    heap.collect();
    try testing.expect(heap.live_structs == null);
    try testing.expect(heap.live_closures == null);
    try testing.expect(heap.live_environments == null);
}

test "the collector reclaims a cycle through a tuple" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    // A tuple holding a closure whose captured scope holds the tuple: neither
    // count ever reaches zero, which is exactly what the collector is for.
    const environment = try heap.createEnvironment();
    const closure = try heap.createClosure(
        .{ .named = "block" },
        try testing.allocator.dupe(*Environment, &.{environment}),
        0,
    );
    heap.releaseEnvironment(environment); // the closure holds it now

    const items = try testing.allocator.alloc(Value, 2);
    const kinds = try testing.allocator.alloc(Value.Kind, 2);
    items[0] = .initInt(1);
    items[1] = .{ .data = .{ .closure = closure } };
    kinds[0] = .int;
    kinds[1] = .closure;
    const tuple = try heap.createTuple(items, kinds);

    try environment.bindings.put(testing.allocator, "pair", .{
        .kind = .tuple,
        .value = .{ .data = .{ .tuple = tuple } },
    });
    tuple.references += 1; // the environment holds it

    // Nothing outside the heap holds any of the three.
    tuple.references -= 1;

    heap.collect();
    try testing.expect(heap.live_tuples == null);
    try testing.expect(heap.live_closures == null);
    try testing.expect(heap.live_environments == null);
}

fn mapOfInts(heap: *Heap, pairs: []const [2]i64) !Value {
    const map = try heap.createMap(.int, .int, false);
    for (pairs) |pair| {
        const key: Value = .initInt(pair[0]);
        try heap.put(map, try Value.hash(testing.allocator, key), key, .initInt(pair[1]));
    }
    return .{ .data = .{ .map = map } };
}

test "a dictionary keeps insertion order, and a replaced value keeps its place" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const value = try mapOfInts(&heap, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 } });
    defer heap.release(value);
    const map = value.data.map;

    // Section 8.4: replacing a value keeps the entry where it was.
    const key: Value = .initInt(2);
    try heap.put(map, try Value.hash(testing.allocator, key), key, .initInt(99));
    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqual(@as(i64, 99), map.entries.items[1].value.data.int);
    try testing.expectEqual(@as(i64, 1), map.entries.items[0].key.data.int);
    try testing.expectEqual(@as(i64, 3), map.entries.items[2].key.data.int);

    // Removing and reinserting moves it to the end.
    _ = try heap.removeKey(map, try Value.hash(testing.allocator, key), key);
    try testing.expectEqual(@as(usize, 2), map.count());
    try heap.put(map, try Value.hash(testing.allocator, key), key, .initInt(7));
    try testing.expectEqual(@as(i64, 2), map.entries.items[2].key.data.int);
}

test "a dictionary finds its keys after it has grown past its first table" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const map = try heap.createMap(.int, .int, false);
    const value: Value = .{ .data = .{ .map = map } };
    defer heap.release(value);

    var at: i64 = 0;
    while (at < 200) : (at += 1) {
        const key: Value = .initInt(at);
        try heap.put(map, try Value.hash(testing.allocator, key), key, .initInt(at * 2));
    }
    try testing.expectEqual(@as(usize, 200), map.count());

    at = 0;
    while (at < 200) : (at += 1) {
        const key: Value = .initInt(at);
        const found = try lookupIn(testing.allocator, map, try Value.hash(testing.allocator, key), key);
        try testing.expectEqual(@as(i64, at * 2), found.?.value.data.int);
    }
    const absent: Value = .initInt(1000);
    try testing.expect(try lookupIn(testing.allocator, map, try Value.hash(testing.allocator, absent), absent) == null);
}

test "removing an entry leaves every later key still findable" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    // Enough entries that removing an early one shifts many, which is exactly
    // what invalidates the indices the table holds.
    const map = try heap.createMap(.int, .int, false);
    const value: Value = .{ .data = .{ .map = map } };
    defer heap.release(value);

    var at: i64 = 0;
    while (at < 50) : (at += 1) {
        const key: Value = .initInt(at);
        try heap.put(map, try Value.hash(testing.allocator, key), key, .initInt(at * 2));
    }

    const removed: Value = .initInt(0);
    _ = try heap.removeKey(map, try Value.hash(testing.allocator, removed), removed);
    try testing.expectEqual(@as(usize, 49), map.count());
    try testing.expect(try lookupIn(testing.allocator, map, try Value.hash(testing.allocator, removed), removed) == null);

    at = 1;
    while (at < 50) : (at += 1) {
        const key: Value = .initInt(at);
        const found = try lookupIn(testing.allocator, map, try Value.hash(testing.allocator, key), key);
        try testing.expectEqual(@as(i64, at * 2), found.?.value.data.int);
    }
}

test "a shared dictionary is copied before it changes" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    var original = try mapOfInts(&heap, &.{.{ 1, 10 }});
    defer heap.release(original);
    var copy = retain(original);
    defer heap.release(copy);

    const separate = try heap.uniqueMap(&copy);
    try testing.expect(separate != original.data.map);
    const key: Value = .initInt(2);
    try heap.put(separate, try Value.hash(testing.allocator, key), key, .initInt(20));
    try testing.expectEqual(@as(usize, 1), original.data.map.count());
    try testing.expectEqual(@as(usize, 2), separate.count());
}

test "the collector reclaims a cycle through a dictionary" {
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const environment = try heap.createEnvironment();
    const closure = try heap.createClosure(
        .{ .named = "block" },
        try testing.allocator.dupe(*Environment, &.{environment}),
        0,
    );
    heap.releaseEnvironment(environment); // the closure holds it now

    const map = try heap.createMap(.int, .closure, false);
    const key: Value = .initInt(1);
    try heap.put(map, try Value.hash(testing.allocator, key), key, .{ .data = .{ .closure = closure } });

    try environment.bindings.put(testing.allocator, "table", .{
        .kind = .map,
        .value = .{ .data = .{ .map = map } },
    });
    map.references += 1; // the environment holds it
    map.references -= 1; // and nothing outside the heap does

    heap.collect();
    try testing.expect(heap.live_maps == null);
    try testing.expect(heap.live_closures == null);
    try testing.expect(heap.live_environments == null);
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
    const closure = try heap.createClosure(.{ .named = "block" }, try testing.allocator.dupe(*Environment, &.{environment}), 0);
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
        const closure = try heap.createClosure(.{ .named = "block" }, try testing.allocator.dupe(*Environment, &.{environment}), 0);
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
