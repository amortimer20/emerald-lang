//! Evaluates a syntax tree.
//!
//! The arithmetic rules are section 5.3's, and they are written out here rather
//! than inherited from the host, because result types and failure modes are
//! exactly what a backend tends to get subtly wrong:
//!
//!   `+` `-` `*`  two `Int`s give an `Int` with overflow checked, otherwise `Float`
//!   `/`          always `Float`
//!   `//`         rounds toward negative infinity; two `Int`s give an `Int`
//!   `%`          paired with `//` by `a == (a // b) * b + (a % b)`
//!   `**`         two `Int`s give an `Int`, and a negative `Int` exponent raises
//!
//! Division by zero is an error for both numeric types, and integer overflow
//! raises rather than wrapping.
//!
//! # The host stack
//!
//! This is a tree-walking interpreter, so every Emerald call and every level of
//! nesting inside one is recursion on the host stack. Section 7.2 requires at
//! least 1,000 active calls, and requires excessive recursion to be detected
//! "before exhausting its host stack". The default stack does not meet the
//! first requirement: a probe with a modestly nested body crashed on 8 MiB
//! between 600 and 800 calls in a Debug build. So `emerald.zig` runs the whole
//! pipeline on a thread whose stack is reserved large enough for 1,000 calls
//! even at the deepest nesting section 3.4 guarantees, and `guardStack` meets
//! the second requirement for any body at all by raising before the
//! reservation runs out.

const std = @import("std");
const Ast = @import("Ast.zig");
const Checker = @import("Checker.zig");
const Diagnostic = @import("Diagnostic.zig");
const Heap = @import("Heap.zig");
const Project = @import("Project.zig");
const Resolver = @import("Resolver.zig");
const Source = @import("Source.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");
const strings = @import("strings.zig");
const unicode = @import("unicode.zig");

const Interpreter = @This();

/// What running a program produced. A failure is the Emerald error that stopped
/// it; section 13 will turn these into catchable values, but nothing can catch
/// anything yet, so one unhandled failure ends the program.
pub const Outcome = struct {
    arena_state: std.heap.ArenaAllocator,
    failure: ?Diagnostic,

    pub fn ok(self: Outcome) bool {
        return self.failure == null;
    }

    pub fn deinit(self: *Outcome) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

const Binding = Heap.Binding;
const Scope = std.StringHashMapUnmanaged(Binding);
const Environment = Heap.Environment;

/// Section 7.2's portable minimum, exactly. The limit above it is a resource
/// boundary rather than language semantics, and the spec gives programs no way
/// to change it.
const max_call_depth = 1000;

/// How much of the host stack this run may use, measured from `base`, the
/// address of a local near the bottom of the thread running the pipeline.
pub const StackLimit = struct {
    base: usize,
    budget: usize,

    /// Room left beneath the budget for whatever runs between two checks, and
    /// for raising the error itself.
    const margin: usize = 1024 * 1024;

    /// Call at the base of the thread, with the size of its stack.
    pub fn here(available: usize) StackLimit {
        var marker: u8 = 0;
        return .{ .base = @intFromPtr(&marker), .budget = available - margin };
    }
};

pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Section 14.1: a module file "initializes once when one of its members is
/// first accessed", and "a cycle reaching an unfinished binding is an
/// initialization-cycle error".
const ModuleState = enum { pending, running, done, failed };

/// `Returned`, `Broke`, and `Continued` are control flow rather than failures:
/// each unwinds through `execute` to the construct that handles it, the way
/// `Raised` unwinds to the top. The checker guarantees every one has a handler.
const Error = error{ Raised, Returned, Broke, Continued } || RunError;

/// Lives as long as the run: hoisted functions, module bindings, and the
/// failure that ends the program.
arena: std.mem.Allocator,
/// Everything that ends with a block or a call: its scope, and the arguments
/// being passed. Freed as each one finishes, so a loop that calls a function a
/// million times does not keep a million dead frames.
gpa: std.mem.Allocator,
/// The program's files. Only the entry file's top level runs; the rest are
/// initialized on first use, which is what section 14.1 asks for.
files: []const Project.File = &.{},
programs: []const Ast.Program = &.{},
/// How far each file's module-level bindings have got. The entry file is
/// `.done` from the start, because its top level is the program.
module_states: []ModuleState = &.{},
/// Which file the statement being executed was written in. It decides what a
/// bare module-level name means and which file a diagnostic points into.
file: u32 = 0,
facts: Resolver.Facts = .{},
out: *std.Io.Writer,
/// Where `input` reads lines from.
in: *std.Io.Reader,
failure: ?Diagnostic = null,
/// One string for each string literal, made the first time the literal runs
/// and shared by every run after it, so a loop that prints a literal does not
/// allocate.
literal_texts: std.AutoHashMapUnmanaged(*const Ast.Expression, *Heap.Text) = .empty,

/// Top-level bindings, from `arena`. A function sees these, and it sees them
/// as they are when it runs; the checker has already proved that everything a
/// call reads is assigned by then.
module: Scope = .empty,
/// Block scopes at the top level, or the current call's own scopes, innermost
/// last. A call replaces this stack for its duration, so a function never sees
/// the block-local names of whoever called it, and a closure's call restores
/// the stack the closure captured.
///
/// Each scope is a counted object rather than a stack frame, because section
/// 7.4's capture is by reference: a closure written inside a block holds that
/// block's environment, and the block ending does not end the variables.
scopes: std.ArrayList(*Environment) = .empty,
/// Environments nothing captured, kept for reuse. A loop body opens a scope
/// every iteration, and taking one from here instead of allocating makes a loop
/// that declares a local cost no allocation at all once it is running.
spare_scopes: std.ArrayList(*Environment) = .empty,

functions: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
/// Fieldless struct constructors, keyed program-wide and carrying their short
/// source name for display.
structs: std.StringHashMapUnmanaged(*const Value.StructType) = .empty,
/// What the checker proved about each function, including return types it
/// inferred, which are needed to widen results the way it allowed.
signatures: *const Type.Signatures,
/// The type the checker gave each list literal, so `[1, 2]` where a `[Float]`
/// is expected is built from `1.0` and `2.0`.
literal_types: *const Checker.LiteralTypes,
/// Every list buffer. See `Heap` for the counting rules this file follows:
/// every new holder of a list retains it, and every holder that ends releases
/// it.
heap: Heap,
call_stack: std.ArrayList(Diagnostic.Frame) = .empty,
/// Set by a `return` for `callFunction` to collect. `return` unwinds through
/// `execute` as `error.Returned`, and this carries its value, the way
/// `failure` carries `error.Raised`'s.
return_value: ?Value = null,

stack: StackLimit,

pub fn run(
    gpa: std.mem.Allocator,
    files: []const Project.File,
    programs: []const Ast.Program,
    signatures: *const Type.Signatures,
    literal_types: *const Checker.LiteralTypes,
    checked_structs: *const Checker.Structs,
    facts: Resolver.Facts,
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    stack: StackLimit,
) RunError!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    const states = try gpa.alloc(ModuleState, files.len);
    defer gpa.free(states);
    var entry: u32 = 0;
    for (files, states, 0..) |file, *state, index| {
        state.* = if (file.entry) .done else .pending;
        if (file.entry) entry = @intCast(index);
    }

    var interpreter: Interpreter = .{
        .arena = arena_state.allocator(),
        .gpa = gpa,
        .files = files,
        .programs = programs,
        .module_states = states,
        .file = entry,
        .facts = facts,
        .out = out,
        .in = in,
        .signatures = signatures,
        .literal_types = literal_types,
        .heap = .init(gpa),
        .stack = stack,
    };
    // Whatever the counts did not reclaim, including lists still held by
    // module bindings and anything an error skipped releasing.
    defer interpreter.heap.deinit();
    defer interpreter.literal_texts.deinit(gpa);

    // Hoisted, matching the resolver and checker. Every file's functions are
    // in place before anything runs, so a call into another file never depends
    // on that file having been reached yet.
    for (programs, 0..) |program, index| {
        interpreter.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data == .struct_declaration) {
                const declaration = statement.data.struct_declaration;
                const checked = checked_structs.get(interpreter.keyOf(declaration.name)).?;
                const checked_fields = checked.user.?.fields;
                const fields = try interpreter.arena.alloc(Value.StructType.Field, checked_fields.len);
                for (checked_fields, fields) |field, *runtime| {
                    runtime.* = .{ .name = field.name, .kind = kindOf(field.type) };
                }
                const descriptor = try interpreter.arena.create(Value.StructType);
                descriptor.* = .{ .name = interpreter.keyOf(declaration.name), .fields = fields };
                try interpreter.structs.put(
                    interpreter.arena,
                    interpreter.keyOf(declaration.name),
                    descriptor,
                );
                continue;
            }
            if (statement.data != .function_declaration) continue;
            const function = statement.data.function_declaration;
            try interpreter.functions.put(interpreter.arena, interpreter.keyOf(function.name), function);
        }
    }
    interpreter.file = entry;

    // Each block and call frees its own scope as it ends, including while an
    // error unwinds through it, so only the lists themselves are left.
    defer interpreter.scopes.deinit(gpa);
    defer interpreter.call_stack.deinit(gpa);
    // A recycled environment is out of the heap's live list, so it is this
    // list's to free.
    defer {
        for (interpreter.spare_scopes.items) |environment| {
            environment.bindings.deinit(gpa);
            gpa.destroy(environment);
        }
        interpreter.spare_scopes.deinit(gpa);
    }

    interpreter.executeAll(programs[entry].statements) catch |err| switch (err) {
        error.Raised => {},
        // The checker rejects `return` outside a function, and section 14.1's
        // top-level `return` is deferred. It rejects `break` and `continue`
        // outside a loop.
        error.Returned, error.Broke, error.Continued => unreachable,
        else => |other| return other,
    };

    const failure = interpreter.failure;
    return .{ .arena_state = arena_state, .failure = failure };
}

/// Raises before the host stack runs out, whatever the shape of the program.
/// Called on every statement and expression, which between them are every
/// point where the evaluator recurses.
fn guardStack(self: *Interpreter, span: Source.Span) Error!void {
    var here: u8 = 0;
    const address = @intFromPtr(&here);
    const base = self.stack.base;
    const used = if (base > address) base - address else address - base;
    if (used <= self.stack.budget) return;

    const innermost = if (self.call_stack.items.len > 0)
        self.call_stack.items[self.call_stack.items.len - 1].function
    else
        return self.raise(
            span,
            "this is nested too deeply to run",
            "Break the expression or block into smaller named pieces.",
        );
    return self.raiseTooMuchRecursion(span, innermost, false);
}

// Statements.

fn executeAll(self: *Interpreter, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| try self.execute(statement);
}

/// Whether a pattern's names are being introduced or already exist.
const Unpack = enum { declare, assign, bind_loop };

/// Section 8.2's unpacking, which is one operation wherever it appears: a
/// declaration, an assignment, a `for` binding, or a block's parameter list.
/// The checker has already proved the arity matches.
fn unpackInto(self: *Interpreter, pattern: Ast.Pattern, value: Value, how: Unpack) Error!void {
    const items = value.data.tuple.items;
    for (pattern.names, items) |name, item| {
        // Section 8.2: `_` discards its position, so nothing holds it.
        if (std.mem.eql(u8, name.text, "_")) continue;

        switch (how) {
            .assign => {
                const slot = self.find(name.text).?;
                const widened = widen(Heap.retain(item), slot.kind);
                if (slot.value) |old| self.heap.release(old);
                slot.value = widened;
            },
            .declare, .bind_loop => {
                const in_block = self.scopes.items.len > 0;
                const key = if (in_block) name.text else self.keyOf(name.text);
                const current = if (in_block)
                    &self.scopes.items[self.scopes.items.len - 1].bindings
                else
                    &self.module;
                const held = Heap.retain(item);
                current.put(if (in_block) self.gpa else self.arena, key, .{
                    .kind = held.kind(),
                    .value = held,
                }) catch |err| {
                    self.heap.release(held);
                    return err;
                };
            },
        }
    }
}

/// Section 6.1 gives every block its own scope, and a local declared inside does
/// not leak out.
fn executeBlock(self: *Interpreter, block: Ast.Block) Error!void {
    _ = try self.pushScope();
    defer self.popScope();
    try self.executeAll(block.statements);
}

fn pushScope(self: *Interpreter) Error!*Environment {
    const environment = if (self.spare_scopes.pop()) |recycled| blk: {
        self.heap.reuseEnvironment(recycled);
        break :blk recycled;
    } else try self.heap.createEnvironment();

    self.scopes.append(self.gpa, environment) catch |err| {
        self.heap.releaseEnvironment(environment);
        return err;
    };
    return environment;
}

/// Ends the innermost scope. A closure created inside it holds it, and then the
/// variables stay alive and keep changing with the closure; otherwise the table
/// is kept, emptied, for the next block.
fn popScope(self: *Interpreter) void {
    const environment = self.scopes.pop().?;
    if (environment.references > 1) {
        environment.references -= 1;
        return;
    }
    self.heap.recycleEnvironment(environment);
    self.spare_scopes.append(self.gpa, environment) catch {
        environment.bindings.deinit(self.gpa);
        self.gpa.destroy(environment);
    };
}

fn execute(self: *Interpreter, statement: Ast.Statement) Error!void {
    try self.guardStack(statement.span);

    switch (statement.data) {
        .expression => |expression| self.heap.release(try self.evaluate(expression)),

        .declaration => |declaration| {
            const initial: ?Value = if (declaration.initializer) |initializer|
                try self.evaluate(initializer)
            else
                null;

            // An annotation fixes the kind; otherwise it comes from the value,
            // which section 4.1 infers the type from.
            const kind: Value.Kind = if (declaration.annotation) |annotation|
                declaredKind(annotation)
            else if (initial) |value|
                value.kind()
            else
                .nothing;

            const in_block = self.scopes.items.len > 0;
            const current = if (in_block) &self.scopes.items[self.scopes.items.len - 1].bindings else &self.module;
            const name = if (in_block) declaration.name else self.keyOf(declaration.name);
            try current.put(if (in_block) self.gpa else self.arena, name, .{
                .kind = kind,
                .value = if (initial) |value| widen(value, kind) else null,
            });
        },

        .destructuring => |destructuring| {
            const value = try self.evaluate(destructuring.initializer);
            defer self.heap.release(value);
            try self.unpackInto(destructuring.pattern, value, .declare);
        },

        .destructuring_assignment => |assignment| {
            // Section 8.2: the complete right side is evaluated before any
            // destination changes, which is what makes a swap a swap.
            const value = try self.evaluate(assignment.value);
            defer self.heap.release(value);
            try self.unpackInto(assignment.pattern, value, .assign);
        },

        .assignment => |assignment| {
            if (assignment.steps.len > 0) return self.assignElement(assignment);
            try self.reach(self.keyOf(assignment.name), assignment.name_span);
            const slot = self.find(assignment.name).?;
            const value = if (assignment.operation) |operation| blk: {
                // Section 5.3 lowers a compound assignment through the same
                // operation as its binary form. The current value is read once.
                // Held while the right side runs, which could reassign the
                // same name through a function and release the old value.
                const current = Heap.retain(slot.value orelse return self.raiseUnassigned(
                    assignment.name_span,
                    assignment.name,
                ));
                defer self.heap.release(current);
                const right = try self.evaluate(assignment.value);
                defer self.heap.release(right);
                break :blk try self.applyBinary(statement.span, operation, current, right);
            } else try self.evaluate(assignment.value);
            if (slot.value) |old| self.heap.release(old);
            slot.value = widen(value, slot.kind);
        },

        .conditional => |conditional| try self.executeConditional(conditional),
        .while_loop => |loop| try self.executeWhile(loop),
        .for_loop => |loop| try self.executeFor(loop),
        .break_statement => return error.Broke,
        .continue_statement => return error.Continued,

        // Hoisted into `self.functions` before anything runs.
        .function_declaration => {},
        // A type declaration describes construction; executing it has no
        // runtime effect.
        .struct_declaration => {},

        .return_statement => |return_statement| {
            self.return_value = if (return_statement.value) |value|
                try self.evaluate(value)
            else
                Value.nothing;
            return error.Returned;
        },
    }
}

/// One step of a runtime path, evaluated from `Ast.Step`: an index carries the
/// value it was evaluated to and the span to blame if it is out of range or
/// missing, and a field carries only the name, since the checker has already
/// proved it exists.
const PlaceStep = union(enum) {
    index: struct { value: Value, span: Source.Span },
    field: []const u8,
};

/// `scores[i] = value`, `grid[i][j] += 1`, or `point.x = 1`.
///
/// Every step's index expression is evaluated first and then the value, left
/// to right as section 5.2 requires. Only then is the path walked, because
/// evaluating the value can change it: a function it calls can append to the
/// same list. Each container on the way down is made unique first, which is
/// copy-on-write: one another binding also holds is copied before anything in
/// it changes.
fn assignElement(self: *Interpreter, assignment: Ast.Assignment) Error!void {
    const steps = try self.gpa.alloc(PlaceStep, assignment.steps.len);
    defer {
        for (steps) |step| switch (step) {
            .index => |index| self.heap.release(index.value),
            .field => {},
        };
        self.gpa.free(steps);
    }
    var built: usize = 0;
    errdefer {
        // Only what was built so far is owned; the rest is undefined.
        for (steps[built..]) |*step| step.* = .{ .field = "" };
    }
    while (built < steps.len) : (built += 1) {
        steps[built] = switch (assignment.steps[built]) {
            .index => |expression| .{ .index = .{ .value = try self.evaluate(expression), .span = expression.span } },
            .field => |field| .{ .field = field.name },
        };
    }

    // Section 14.1: a non-entry file initializes on first use, which this is,
    // exactly as a plain assignment already reaches before finding its slot.
    try self.reach(self.keyOf(assignment.name), assignment.name_span);
    const binding = self.find(assignment.name).?;
    const root = &binding.value.?;

    if (assignment.operation) |operation| {
        // Section 5.2: the current value is read once, before the right side,
        // and held while the right side runs, as for a plain name.
        const current = Heap.retain(try self.elementValue(root, steps));
        defer self.heap.release(current);
        const right = try self.evaluate(assignment.value);
        defer self.heap.release(right);
        const result = try self.applyBinary(assignment.target_span, operation, current, right);
        return self.storeElement(root, steps, result);
    }

    const value = try self.evaluate(assignment.value);
    return self.storeElement(root, steps, value);
}

/// The position of `name` among a struct instance's fields. The checker has
/// already proved it exists, exactly as `evaluateProperty` trusts for a read.
fn fieldPosition(instance: *const Heap.StructValue, name: []const u8) usize {
    for (instance.descriptor.fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, name)) return index;
    }
    unreachable;
}

/// What a compound assignment reads before it writes. A dictionary entry that
/// is not there has no value to add to, which is the one place a bracket on a
/// dictionary can fail.
fn elementValue(self: *Interpreter, root: *Value, steps: []const PlaceStep) Error!Value {
    var at = root.*;
    for (steps) |step| switch (step) {
        .field => |name| {
            const instance = at.data.struct_value;
            at = instance.fields[fieldPosition(instance, name)];
        },
        .index => |index| {
            if (at.data == .map) {
                const map = at.data.map;
                const key = widen(Heap.retain(index.value), map.key_kind);
                defer self.heap.release(key);
                const hash = try self.hashKey(index.span, key);
                const entry = try Heap.lookupIn(self.gpa, map, hash, key) orelse
                    return self.raiseMissingKey(index.span, key);
                at = entry.value;
                continue;
            }
            const list = at.data.list;
            const position = try self.checkIndex(list, index.value.data.int, index.span);
            at = list.items.items[position];
        },
    };
    return at;
}

/// Stores `value`, taking over one holder of it. Every container on the way is
/// made safe to change first, which is where section 8.1's value semantics is
/// enforced for structs and dictionaries as it already was for lists.
fn storeElement(self: *Interpreter, root: *Value, steps: []const PlaceStep, value: Value) Error!void {
    var slot = root;
    for (steps, 0..) |step, step_index| {
        const last = step_index + 1 == steps.len;

        switch (step) {
            .field => |name| {
                const instance = try self.heap.uniqueStruct(slot);
                const position = fieldPosition(instance, name);
                if (last) {
                    self.heap.release(instance.fields[position]);
                    instance.fields[position] = widen(value, instance.descriptor.fields[position].kind);
                    return;
                }
                slot = &instance.fields[position];
            },
            .index => |index| {
                if (slot.data == .map) {
                    const map = try self.heap.uniqueMap(slot);
                    // Section 4.4: a whole number written where a `Float` key
                    // belongs is stored as one, exactly as a value is.
                    // Without this the entry would print as `2` in a
                    // dictionary whose keys are `Float`.
                    const key = widen(Heap.retain(index.value), map.key_kind);
                    defer self.heap.release(key);
                    const hash = try self.hashKey(index.span, key);
                    if (last) {
                        // Section 8.3: this inserts or replaces, and never fails.
                        return self.heap.put(map, hash, Heap.retain(key), widen(value, map.value_kind));
                    }
                    const found = switch (try self.heap.locate(map, hash, key)) {
                        .entry => |found| found,
                        .vacancy => return self.raiseMissingKey(index.span, key),
                    };
                    slot = &map.entries.items[found].value;
                    continue;
                }

                const list = try self.heap.unique(slot);
                const position = try self.checkIndex(list, index.value.data.int, index.span);
                if (last) {
                    self.heap.release(list.items.items[position]);
                    list.items.items[position] = widen(value, list.element);
                    return;
                }
                slot = &list.items.items[position];
            },
        }
    }
}

/// The slot a path of indices and fields reaches, for a method that changes
/// what it finds there. Every container on the way is made safe to change
/// first.
fn containerSlot(self: *Interpreter, root: *Value, steps: []const PlaceStep) Error!*Value {
    var slot = root;
    for (steps) |step| switch (step) {
        .field => |name| {
            const instance = try self.heap.uniqueStruct(slot);
            slot = &instance.fields[fieldPosition(instance, name)];
        },
        .index => |index| {
            if (slot.data == .map) {
                const map = try self.heap.uniqueMap(slot);
                const key = widen(Heap.retain(index.value), map.key_kind);
                defer self.heap.release(key);
                const hash = try self.hashKey(index.span, key);
                const found = switch (try self.heap.locate(map, hash, key)) {
                    .entry => |at| at,
                    .vacancy => return self.raiseMissingKey(index.span, key),
                };
                slot = &map.entries.items[found].value;
                continue;
            }
            const list = try self.heap.unique(slot);
            const position = try self.checkIndex(list, index.value.data.int, index.span);
            slot = &list.items.items[position];
        },
    };
    return slot;
}

fn raiseMissingKey(self: *Interpreter, span: Source.Span, key: Value) Error {
    var written: std.Io.Writer.Allocating = .init(self.arena);
    key.write(&written.writer, true) catch return error.OutOfMemory;
    return self.raiseFmt(
        span,
        "there is no entry for {s}",
        .{written.written()},
        "Put a value there first, as in `scores[key] = 0`, or check with `contains_key?(key)`.",
    );
}

/// Section 5.4: an index outside the list is an error that names the index and
/// the valid range.
fn checkIndex(self: *Interpreter, list: *const Heap.List, index: i64, span: Source.Span) Error!usize {
    const count = list.items.items.len;
    if (index >= 0 and index < count) return @intCast(index);
    if (count == 0) return self.raiseFmt(
        span,
        "index {d} is outside this list, which is empty",
        .{index},
        "Check `empty?()` before indexing, or add an element first.",
    );
    const help = try std.fmt.allocPrint(self.arena, "Valid indices are 0 through {d}.", .{count - 1});
    return self.raiseFmt(
        span,
        "index {d} is outside this list, which has {d} element{s}",
        .{ index, count, if (count == 1) "" else "s" },
        help,
    );
}

/// Section 6.4. Each pass through the body is a block of its own, so its locals
/// are fresh every time.
fn executeWhile(self: *Interpreter, loop: Ast.While) Error!void {
    while (try self.condition(loop.condition)) {
        self.executeBlock(loop.body) catch |err| switch (err) {
            error.Broke => return,
            error.Continued => continue,
            else => return err,
        };
    }
}

/// Section 6.4's counting loops: `a..b`, `a..<b`, `a.up_to(b)`, and
/// `a.down_to(b)`, with an optional `.step(n)` and `.reverse()`. Everything
/// is evaluated once, before the first iteration.
///
/// The loop stops by comparing with the last value it will visit rather than
/// by stepping past it, because stepping past either end of the `Int` range
/// would overflow. `Counting` keeps that last value exact.
fn executeFor(self: *Interpreter, loop: Ast.For) Error!void {
    if (!Checker.isCounting(loop.iterable)) return self.executeForList(loop);

    const counting = try self.evaluateCounting(loop.iterable) orelse return;
    var current = counting.first;
    while (try self.executeIteration(loop, .initInt(current))) {
        if (current == counting.last) return;
        // Cannot overflow: `last` is reachable from `current` in whole steps.
        current = if (counting.descending) current - counting.step else current + counting.step;
    }
}

/// A nonempty run of whole numbers: from `first` to `last`, both visited, `step`
/// apart, counting down when `descending`. `last` is always a value the count
/// actually reaches, which is what lets `reverse` swap the ends exactly.
const Counting = struct {
    first: i64,
    last: i64,
    step: i64 = 1,
    descending: bool,

    /// The last value reached from `first` in whole steps without passing
    /// `bound`, which the caller guarantees lies in the counting direction.
    fn reaching(first: i64, bound: i64, step: i64, descending: bool) Counting {
        const difference = @as(i128, bound) - first;
        const distance: i128 = if (difference < 0) -difference else difference;
        const whole = distance - @rem(distance, step);
        const last: i64 = @intCast(if (descending) @as(i128, first) - whole else @as(i128, first) + whole);
        return .{ .first = first, .last = last, .step = step, .descending = descending };
    }
};

/// Null for a count that visits nothing.
fn evaluateCounting(self: *Interpreter, expression: *const Ast.Expression) Error!?Counting {
    if (expression.data == .range) {
        const range = expression.data.range;
        const start = (try self.evaluate(range.start)).data.int;
        const end = (try self.evaluate(range.end)).data.int;
        if (range.inclusive) {
            return if (start > end) null else .{ .first = start, .last = end, .descending = false };
        }
        return if (start >= end) null else .{ .first = start, .last = end - 1, .descending = false };
    }

    const call = expression.data.call;
    const member = call.callee.data.member;
    const name = member.name;

    if (std.mem.eql(u8, name, "up_to") or std.mem.eql(u8, name, "down_to")) {
        const start = (try self.evaluate(member.base)).data.int;
        const end = (try self.evaluate(call.arguments[0])).data.int;
        // A target on the wrong side counts nothing, as `0..count - 1` does
        // for an empty list.
        const descending = std.mem.eql(u8, name, "down_to");
        if (if (descending) start < end else start > end) return null;
        return .{ .first = start, .last = end, .descending = descending };
    }

    const base = try self.evaluateCounting(member.base);

    if (std.mem.eql(u8, name, "reverse")) {
        const counting = base orelse return null;
        return .{
            .first = counting.last,
            .last = counting.first,
            .step = counting.step,
            .descending = !counting.descending,
        };
    }

    // `step`, evaluated even when the count is empty, so a bad step is always
    // reported.
    const distance = (try self.evaluate(call.arguments[0])).data.int;
    if (distance < 1) return self.raiseFmt(
        call.arguments[0].span,
        "a step must be at least 1, but this is {d}",
        .{distance},
        "The range says which way to count; the step says only how far, as in `10.down_to(0).step(2)`.",
    );
    const counting = base orelse return null;
    return Counting.reaching(counting.first, counting.last, distance, counting.descending);
}

/// Section 8.4: the loop visits the list as it was when the loop began. Holding
/// the buffer for the whole loop is what guarantees it: a change the body makes
/// through the list's own binding finds the buffer shared and copies it first.
fn executeForList(self: *Interpreter, loop: Ast.For) Error!void {
    const iterable = try self.evaluate(loop.iterable);
    defer self.heap.release(iterable);

    // Section 9.1: a string yields its characters, each a string of its own.
    if (iterable.data == .string) {
        var clusters: unicode.Graphemes = .init(iterable.data.string.bytes);
        while (clusters.next()) |cluster| {
            if (!try self.executeIteration(loop, try self.heap.copyText(cluster))) return;
        }
        return;
    }

    // Section 8.4: a dictionary or set is visited in insertion order, and the
    // loop sees the collection as it was when it began. The entries are copied
    // first, so changing the collection inside the body cannot move the ground
    // underneath the walk.
    if (iterable.data == .map) {
        const map = iterable.data.map;
        const entries = try self.gpa.dupe(Heap.Map.Entry, map.entries.items);
        defer self.gpa.free(entries);
        for (entries) |entry| {
            _ = Heap.retain(entry.key);
            _ = Heap.retain(entry.value);
        }
        // `pending` moves past an entry before anything consumes it, so a
        // `break` or an error releases exactly the ones still untouched.
        var pending: usize = 0;
        defer for (entries[pending..]) |entry| {
            self.heap.release(entry.key);
            self.heap.release(entry.value);
        };
        while (pending < entries.len) {
            const entry = entries[pending];
            pending += 1;
            // A set's value is `nothing`, which holds nothing to release.
            const item = if (map.is_set) entry.key else try self.entryTuple(map, entry);
            if (!try self.executeIteration(loop, item)) return;
        }
        return;
    }

    for (iterable.data.list.items.items) |item| {
        if (!try self.executeIteration(loop, Heap.retain(item))) return;
    }
}

/// Section 8.6's `(key, value)`, which is the one item a dictionary's block and
/// `for` loop receive. Takes over one holder of each half.
fn entryTuple(self: *Interpreter, map: *const Heap.Map, entry: Heap.Map.Entry) Error!Value {
    const items = try self.gpa.alloc(Value, 2);
    const kinds = self.gpa.alloc(Value.Kind, 2) catch |err| {
        self.gpa.free(items);
        return err;
    };
    items[0] = entry.key;
    items[1] = entry.value;
    kinds[0] = map.key_kind;
    kinds[1] = map.value_kind;
    errdefer {
        self.heap.release(entry.key);
        self.heap.release(entry.value);
    }
    return .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
}

/// One pass through a `for` body with the loop variable bound to `value`, in a
/// scope of its own, which is what makes the binding fresh every iteration.
/// `value` is owned: the binding takes it, and `_` releases it. False when a
/// `break` ended the loop.
fn executeIteration(self: *Interpreter, loop: Ast.For, value: Value) Error!bool {
    const scope = try self.pushScope();
    defer self.popScope();

    if (loop.pattern) |pattern| {
        defer self.heap.release(value);
        try self.unpackInto(pattern, value, .bind_loop);
    } else if (std.mem.eql(u8, loop.name, "_")) {
        self.heap.release(value);
    } else {
        scope.bindings.put(self.gpa, loop.name, .{ .kind = value.kind(), .value = value }) catch |err| {
            self.heap.release(value);
            return err;
        };
    }

    self.executeAll(loop.body.statements) catch |err| switch (err) {
        error.Broke => return false,
        error.Continued => {},
        else => return err,
    };
    return true;
}

fn executeConditional(self: *Interpreter, conditional: Ast.If) Error!void {
    if (try self.condition(conditional.condition)) {
        return self.executeBlock(conditional.then_block);
    }
    if (conditional.otherwise) |otherwise| switch (otherwise) {
        .block => |block| return self.executeBlock(block),
        .chained => |chained| return self.execute(chained.*),
    };
}

/// Section 4.4: conditions require `Bool`. Values do not become truthy or falsey
/// implicitly, so a number here is an error rather than a silent coercion.
fn condition(self: *Interpreter, expression: *const Ast.Expression) Error!bool {
    const value = try self.evaluate(expression);
    return switch (value.data) {
        .bool => |result| result,
        else => self.raiseFmt(
            expression.span,
            "a condition must be a Bool, but this is {s}",
            .{value.typeName()},
            "Compare it to something, as in `count > 0`. Emerald has no truthy or falsey values.",
        ),
    };
}

/// Applies section 4.4's widening, which is the only implicit conversion in the
/// language. Anything else is already a type error the checker reported.
fn widen(value: Value, kind: Value.Kind) Value {
    if (kind != .float) return value;
    return switch (value.data) {
        .int => |number| .initFloat(@floatFromInt(number)),
        else => value,
    };
}

fn declaredKind(annotation: Ast.TypeExpression) Value.Kind {
    if (annotation.key != null or annotation.set) return .map;
    if (annotation.element != null) return .list;
    if (annotation.positions != null) return .tuple;
    if (annotation.signature != null) return .closure;
    return if (Type.fromName(annotation.name)) |builtin| kindOf(builtin) else .struct_value;
}

/// The runtime kind for a checked type. `.invalid` never reaches a program that
/// passed checking.
fn kindOf(checked: Type) Value.Kind {
    return switch (checked.kind) {
        .nothing, .invalid => .nothing,
        .bool => .bool,
        .int => .int,
        .float => .float,
        .string => .string,
        .list => .list,
        .tuple => .tuple,
        .dictionary, .set => .map,
        .function => .closure,
        .struct_value => .struct_value,
    };
}

/// The one name the whole program knows a module-level declaration by, as the
/// resolver worked it out for the file being executed. A local is its own key.
fn keyOf(self: *Interpreter, name: []const u8) []const u8 {
    return self.facts.keyFor(self.file, name) orelse name;
}

fn find(self: *Interpreter, name: []const u8) ?*Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].bindings.getPtr(name)) |slot| return slot;
    }
    return self.module.getPtr(self.keyOf(name));
}

/// Section 14.1: a file that is not the entry initializes once, the first time
/// anything reaches one of its members. Called wherever a module-level key is
/// about to be read, assigned, or called.
fn reach(self: *Interpreter, key: []const u8, span: Source.Span) Error!void {
    const owner = self.facts.owner.get(key) orelse return;
    switch (self.module_states[owner]) {
        .done => return,
        .pending => return self.initializeModule(owner),
        .running => {
            // Section 14.1's cycle is a cycle "reaching an unfinished
            // binding". A function is hoisted, so reaching one is never that,
            // and a binding the file has already got to is finished.
            if (self.functions.contains(key)) return;
            if (self.module.get(key)) |slot| {
                if (slot.value != null) return;
            }
            return self.raiseFmt(
                span,
                "`{s}` is still being set up, so `{s}` cannot be read yet",
                .{ self.files[owner].source.path, key },
                "Two values are waiting on each other. Break the cycle by moving one into a function, which runs when it is called rather than when the file is set up.",
            );
        },
        // Unreachable while nothing can catch a failure: the first one ends the
        // program. Section 13 is where a later access becomes possible.
        .failed => return self.raiseFmt(
            span,
            "`{s}` could not be set up",
            .{self.files[owner].source.path},
            "An earlier error stopped it. Fix that first.",
        ),
    }
}

/// Section 14.1: the file's module-level bindings, in declaration order, run
/// once. Only `reach` calls this, and only for a file that has not started.
fn initializeModule(self: *Interpreter, file: u32) Error!void {
    self.module_states[file] = .running;
    errdefer self.module_states[file] = .failed;

    // Its declarations run against the module scope alone, in the file they
    // were written in, whatever was executing when they were reached.
    const outer_file = self.file;
    const outer_scopes = self.scopes;
    self.file = file;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
        self.file = outer_file;
    }

    // Declaration order, which is the order section 14.1 gives them.
    for (self.programs[file].statements) |statement| {
        switch (statement.data) {
            .declaration, .destructuring => try self.execute(statement),
            else => {},
        }
    }

    self.module_states[file] = .done;
}

// Expressions.

fn evaluate(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    try self.guardStack(expression.span);

    return switch (expression.data) {
        .int_literal => |value| .initInt(value),
        .float_literal => |value| .initFloat(value),
        .bool_literal => |value| .initBool(value),
        .nothing_literal => Value.nothing,
        // Reading a name makes a new holder of what it holds.
        .name => |name| self.evaluateName(expression, self.keyOf(name), name),
        .unary => |unary| self.evaluateUnary(expression, unary),
        .binary => |binary| self.evaluateBinary(expression, binary),
        .logical => |logical| self.evaluateLogical(logical),
        .comparison => |comparison| self.evaluateComparison(expression, comparison),
        .call => |call| self.evaluateCall(expression, call),
        // The checker allows a range only as what a `for` loop visits, which
        // `executeFor` reads directly.
        .range => unreachable,
        .list_literal => |elements| self.evaluateList(expression, elements),
        .dictionary_literal => |entries| self.evaluateDictionary(expression, entries),
        .tuple_literal => |positions| self.evaluateTuple(expression, positions),
        .index => |index| self.evaluateIndex(expression, index),
        // A namespace-qualified name is a reference, not a property access.
        .member => |member| if (self.facts.qualified.get(expression)) |key|
            self.evaluateName(expression, key, key)
        else
            self.evaluateProperty(member),
        .string_literal => |bytes| self.evaluateStringLiteral(expression, bytes),
        .interpolation => |parts| self.evaluateInterpolation(parts),
        .lambda => self.evaluateLambda(expression),
    };
}

/// Section 7.4: a lambda captures the scopes it can see, not copies of what
/// they hold, so a closure and the block around it keep sharing every variable.
/// The module is not captured because it is visible from everywhere anyway.
fn evaluateLambda(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    const captured = try self.gpa.dupe(*Environment, self.scopes.items);
    // A block can be passed to another file and called there, so it remembers
    // where it was written: that is what its bare module-level names mean.
    return .{ .data = .{
        .closure = try self.heap.createClosure(.{ .lambda = expression }, captured, self.file),
    } };
}

/// A name read for its value, whether it was written bare or qualified.
/// `key` is what the program calls it; `written` is what the reader typed, so a
/// diagnostic echoes that back.
fn evaluateName(
    self: *Interpreter,
    expression: *const Ast.Expression,
    key: []const u8,
    written: []const u8,
) Error!Value {
    try self.reach(key, expression.span);
    if (self.find(written)) |slot| {
        if (slot.value) |value| return Heap.retain(value);
        return self.raiseUnassigned(expression.span, written);
    }
    if (self.module.getPtr(key)) |slot| {
        if (slot.value) |value| return Heap.retain(value);
        return self.raiseUnassigned(expression.span, written);
    }
    // Section 7.5: a bare function name is its callable value.
    if (self.functions.contains(key)) return self.evaluateFunctionValue(key);
    // The checker proves every name read here is bound and assigned, so this is
    // a safety net rather than a language rule.
    return self.raiseUnassigned(expression.span, written);
}

/// Section 7.5's captured named function, which captures nothing: a named
/// function's body can only see the module, which is always visible.
fn evaluateFunctionValue(self: *Interpreter, name: []const u8) Error!Value {
    const captured = try self.gpa.alloc(*Environment, 0);
    return .{ .data = .{ .closure = try self.heap.createClosure(.{ .named = name }, captured, self.file) } };
}

// Every case of `evaluate` that needs locals of its own lives in a function
// like these. `evaluate` runs once per level of nesting, so every byte of its
// frame is multiplied by section 7.2's 1,000 calls times the deepest nesting
// section 3.4 allows, and a Debug build gives each local its own slot.

/// Section 8.5's properties: `count`, and a list's `first` and `last`. The
/// checker allows nothing else here.
fn evaluateProperty(self: *Interpreter, member: Ast.Expression.Member) Error!Value {
    const base = try self.evaluate(member.base);
    defer self.heap.release(base);

    // Section 8.2's `entry.0`. The checker has proved the position exists, so
    // there is nothing to fail here.
    if (member.position) |position| {
        return Heap.retain(base.data.tuple.items[position]);
    }

    if (base.data == .struct_value) {
        const instance = base.data.struct_value;
        for (instance.descriptor.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, member.name)) return Heap.retain(instance.fields[index]);
        }
        unreachable;
    }

    if (base.data == .string) {
        // Section 9.2: a string's count is its characters, not its bytes.
        return .initInt(@intCast(unicode.graphemeCount(base.data.string.bytes)));
    }

    // Section 8.5: `count` is the only property a dictionary or set has.
    if (base.data == .map) return .initInt(@intCast(base.data.map.count()));

    const items = base.data.list.items.items;
    if (std.mem.eql(u8, member.name, "count")) return .initInt(@intCast(items.len));
    // Section 4.5: absent rather than an error, because an empty list has no
    // first element to name. `empty?` is the companion that tells the two apart.
    if (items.len == 0) return Value.nothing;
    return Heap.retain(if (std.mem.eql(u8, member.name, "first")) items[0] else items[items.len - 1]);
}

fn evaluateStringLiteral(self: *Interpreter, expression: *const Ast.Expression, bytes: []const u8) Error!Value {
    const cached = try self.literal_texts.getOrPut(self.gpa, expression);
    if (!cached.found_existing) cached.value_ptr.* = try self.heap.literalText(bytes);
    return .{ .data = .{ .string = cached.value_ptr.* } };
}

/// Section 5.1: each interpolated value appears as `print` would display it.
fn evaluateInterpolation(self: *Interpreter, parts: []const Ast.Expression.Part) Error!Value {
    var built: std.Io.Writer.Allocating = .init(self.gpa);
    defer built.deinit();
    for (parts) |part| switch (part) {
        .text => |bytes| try built.writer.writeAll(bytes),
        .expression => |part_expression| {
            const value = try self.evaluate(part_expression);
            defer self.heap.release(value);
            try value.display(&built.writer);
        },
    };
    return .{ .data = .{ .string = try self.heap.createText(try built.toOwnedSlice()) } };
}

/// Section 8.2. The checker recorded the literal's type, which says whether
/// whole numbers in it are to be stored as `Float`s.
/// Section 8.2's `["Ava": 12]`. A duplicate key that only shows up at runtime
/// keeps its position and takes the later value (8.4), which is what `put`
/// already does.
fn evaluateDictionary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    entries: []const Ast.Expression.Entry,
) Error!Value {
    const checked = self.literal_types.get(expression).?;
    const key_kind = kindOf(checked.key.?.*);
    const value_kind = kindOf(checked.element.?.*);

    const map = try self.heap.createMap(key_kind, value_kind, false);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (entries) |entry| {
        const key = widen(try self.evaluate(entry.key), key_kind);
        const hash = try self.hashKey(entry.key.span, key);
        const value = widen(try self.evaluate(entry.value), value_kind);
        try self.heap.put(map, hash, key, value);
    }
    return result;
}

/// Section 8.3: NaN is rejected as a key, directly or inside a tuple, because
/// it is not equal to itself and so could never be found again.
fn hashKey(self: *Interpreter, span: Source.Span, key: Value) Error!u64 {
    if (holdsNan(key)) return self.raise(
        span,
        "a not-a-number value cannot be a key",
        "`nan?` is never equal to anything, including itself, so nothing stored under it could be found again.",
    );
    return Value.hash(self.gpa, key);
}

fn holdsNan(value: Value) bool {
    return switch (value.data) {
        .float => |number| std.math.isNan(number),
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (holdsNan(item)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn evaluateList(self: *Interpreter, expression: *const Ast.Expression, elements: []const *const Ast.Expression) Error!Value {
    const checked = self.literal_types.get(expression).?;

    // Section 8.2: the same bracketed elements are a set where a set was
    // expected, and an empty `[]` is whichever of the three was.
    if (checked.kind == .set or checked.kind == .dictionary) {
        return self.evaluateSet(elements, checked);
    }

    const element = kindOf(checked.element.?.*);

    const list = try self.heap.createList(element, elements.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (elements) |item| list.items.appendAssumeCapacity(widen(try self.evaluate(item), element));
    return result;
}

/// Section 8.2's `("score", 10)`. The checker recorded the position types, so a
/// whole number written where a `Float` was expected is stored as one, exactly
/// as a list literal's elements are.
fn evaluateTuple(
    self: *Interpreter,
    expression: *const Ast.Expression,
    positions: []const *const Ast.Expression,
) Error!Value {
    const checked = self.literal_types.get(expression).?;

    const items = try self.gpa.alloc(Value, positions.len);
    const kinds = self.gpa.alloc(Value.Kind, positions.len) catch |err| {
        self.gpa.free(items);
        return err;
    };
    for (kinds, checked.elements) |*slot, element| slot.* = kindOf(element);

    // Filled one at a time, so a failure part-way releases only what is built.
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| self.heap.release(item);
        self.gpa.free(items);
        self.gpa.free(kinds);
    }
    while (built < positions.len) : (built += 1) {
        items[built] = widen(try self.evaluate(positions[built]), kinds[built]);
    }

    return .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
}

/// A bracketed literal the checker decided was a set, or an empty one it
/// decided was a set or a dictionary.
fn evaluateSet(
    self: *Interpreter,
    elements: []const *const Ast.Expression,
    checked: Type,
) Error!Value {
    const set = checked.kind == .set;
    const member_kind = kindOf(checked.element.?.*);
    const map = try self.heap.createMap(
        if (set) member_kind else kindOf(checked.key.?.*),
        if (set) .nothing else member_kind,
        set,
    );
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (elements) |element| {
        const member = widen(try self.evaluate(element), member_kind);
        const hash = try self.hashKey(element.span, member);
        try self.heap.put(map, hash, member, Value.nothing);
    }
    return result;
}

fn evaluateIndex(self: *Interpreter, expression: *const Ast.Expression, index: Ast.Expression.Index) Error!Value {
    const base = try self.evaluate(index.base);
    defer self.heap.release(base);

    // Section 8.3: a dictionary lookup can miss, and reports that as absence
    // rather than as an error, which is what makes `.or(0)` the natural reply.
    if (base.data == .map) {
        const map = base.data.map;
        const key = widen(try self.evaluate(index.index), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(index.index.span, key);
        const entry = try Heap.lookupIn(self.gpa, map, hash, key) orelse return Value.nothing;
        return Heap.retain(entry.value);
    }

    const position = (try self.evaluate(index.index)).data.int;
    if (base.data == .string) return self.characterAt(expression.span, base.data.string.bytes, position);
    const list = base.data.list;
    const at = try self.checkIndex(list, position, expression.span);
    return Heap.retain(list.items.items[at]);
}

/// Section 9.1: indexing a string counts characters, from zero.
fn characterAt(self: *Interpreter, span: Source.Span, bytes: []const u8, position: i64) Error!Value {
    if (strings.characterAt(bytes, position)) |character| return self.heap.copyText(character);
    const count = unicode.graphemeCount(bytes);
    if (count == 0) return self.raiseFmt(
        span,
        "index {d} is outside this String, which is empty",
        .{position},
        "Check `empty?()` before indexing.",
    );
    const help = try std.fmt.allocPrint(self.arena, "Valid indices are 0 through {d}.", .{count - 1});
    return self.raiseFmt(
        span,
        "index {d} is outside this String, which has {d} character{s}",
        .{ position, count, if (count == 1) "" else "s" },
        help,
    );
}

/// Section 5.2's `and` and `or`, which short-circuit: the right side is not
/// evaluated when the left already decides the answer.
fn evaluateLogical(self: *Interpreter, logical: Ast.Expression.Logical) Error!Value {
    const left = try self.condition(logical.left);
    const decided = switch (logical.operator) {
        .conjunction => !left,
        .disjunction => left,
    };
    if (decided) return .initBool(left);
    return .initBool(try self.condition(logical.right));
}

/// A comparison chain such as `0 <= score <= 100`.
///
/// Section 5.2 requires each operand to be evaluated once and the chain to
/// short-circuit as if joined by `and`. Carrying the previous value forward
/// gives both: `score` is evaluated once even though two comparisons use it, and
/// a false link returns before the next operand is touched.
fn evaluateComparison(
    self: *Interpreter,
    expression: *const Ast.Expression,
    comparison: Ast.Expression.Comparison,
) Error!Value {
    // Each operand is released once the comparison after it is decided. The
    // `defer` reads `left` when it runs, so it releases whichever is current.
    var left = try self.evaluate(comparison.operands[0]);
    defer self.heap.release(left);

    for (comparison.operators, comparison.operands[1..]) |operator, operand_node| {
        const right = try self.evaluate(operand_node);

        const holds = if (operator.isEquality())
            (try Value.equals(self.gpa, left, right)) == (operator == .equal)
        else if (left.data == .string and right.data == .string)
            // Section 9.2: by the code points of the normalized forms.
            operator.holds(try unicode.order(self.gpa, left.data.string.bytes, right.data.string.bytes))
        else if (Value.order(left, right)) |ordering|
            operator.holds(ordering)
        else if (left.isNumber() and right.isNumber())
            // Unordered means a NaN is involved. Section 5.3 keeps IEEE
            // behavior, under which every comparison is false except `!=`.
            operator == .not_equal
        else
            return self.raiseFmt(
                expression.span,
                "{s} and {s} cannot be compared",
                .{ left.typeName(), right.typeName() },
                "Comparison needs two values of the same kind.",
            );

        self.heap.release(left);
        left = right;
        if (!holds) return .initBool(false);
    }

    return .initBool(true);
}

fn evaluateUnary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    unary: Ast.Expression.Unary,
) Error!Value {
    const operand = try self.evaluate(unary.operand);
    switch (unary.operator) {
        .negate => switch (operand.data) {
            // Negating the minimum `Int` overflows like any other operation,
            // because the range is asymmetric.
            .int => |value| {
                const result = @subWithOverflow(@as(i64, 0), value);
                if (result[1] != 0) return self.raiseFmt(
                    expression.span,
                    "negating {d} overflows Int",
                    .{value},
                    integer_range_help,
                );
                return .initInt(result[0]);
            },
            .float => |value| return .initFloat(-value),
            .nothing, .bool, .string, .list, .tuple, .map, .closure, .struct_value => return self.raiseFmt(
                expression.span,
                "`-` needs a number, but this is {s}",
                .{operand.typeName()},
                "Use `not` to invert a Bool.",
            ),
        },
        .not => switch (operand.data) {
            .bool => |value| return .initBool(!value),
            else => return self.raiseFmt(
                expression.span,
                "`not` needs a Bool, but this is {s}",
                .{operand.typeName()},
                "Compare it to something first, as in `not (count > 0)`.",
            ),
        },
    }
}

fn evaluateBinary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    binary: Ast.Expression.Binary,
) Error!Value {
    // Section 5.2 evaluates ordered expression lists left to right.
    const left = try self.evaluate(binary.left);
    defer self.heap.release(left);
    const right = try self.evaluate(binary.right);
    defer self.heap.release(right);
    return self.applyBinary(expression.span, binary.operator, left, right);
}

/// Shared by binary expressions and compound assignment, which section 5.3
/// lowers through the same operation.
fn applyBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: Value,
    right: Value,
) Error!Value {
    // `+` joins two strings into a new one. The operands stay the caller's to
    // release: compound assignment passes a binding's value without retaining.
    if (left.data == .string and right.data == .string) {
        const joined = try std.mem.concat(self.gpa, u8, &.{ left.data.string.bytes, right.data.string.bytes });
        return .{ .data = .{ .string = try self.heap.createText(joined) } };
    }
    if (!left.isNumber() or !right.isNumber()) return self.raiseFmt(
        span,
        "{s} needs numbers, but this is {s} and {s}",
        .{ operator.describe(), left.typeName(), right.typeName() },
        "Arithmetic works on Int and Float.",
    );

    // This one always produces a Float regardless of operand types.
    if (operator == .divide) {
        const divisor = toFloat(right);
        if (divisor == 0) return self.raiseDivisionByZero(span, operator);
        return .initFloat(toFloat(left) / divisor);
    }

    const both_int = left.data == .int and right.data == .int;
    if (!both_int) return self.evaluateFloatBinary(span, operator, toFloat(left), toFloat(right));

    return self.evaluateIntBinary(span, operator, left.data.int, right.data.int);
}

fn evaluateIntBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: i64,
    right: i64,
) Error!Value {
    switch (operator) {
        .add, .subtract, .multiply => {
            const result = switch (operator) {
                .add => @addWithOverflow(left, right),
                .subtract => @subWithOverflow(left, right),
                .multiply => @mulWithOverflow(left, right),
                else => unreachable,
            };
            if (result[1] != 0) return self.raiseFmt(
                span,
                "{s} of {d} and {d} overflows Int",
                .{ operator.describe(), left, right },
                integer_range_help,
            );
            return .initInt(result[0]);
        },
        .floor_divide => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // The only overflowing quotient: the minimum Int divided by -1 has
            // no positive counterpart in an asymmetric range.
            if (left == std.math.minInt(i64) and right == -1) return self.raiseFmt(
                span,
                "{s} of {d} and {d} overflows Int",
                .{ operator.describe(), left, right },
                integer_range_help,
            );
            return .initInt(@divFloor(left, right));
        },
        .remainder => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // Every value is exactly divisible by -1, so the remainder is zero.
            // Stating it avoids relying on host behavior at the range edge.
            if (right == -1) return .initInt(0);
            return .initInt(@mod(left, right));
        },
        .power => return self.evaluateIntPower(span, left, right),
        .divide => unreachable, // handled before operand kinds matter
    }
}

/// Section 5.3: two `Int`s give an `Int`, so `side ** 2` stays whole. An `Int`
/// has no fraction to hold `2 ** -1`, so a negative exponent raises and points
/// at the `Float` spelling.
///
/// Squaring by repeated halving takes as many steps as the exponent has bits,
/// so `1 ** 1_000_000_000` is instant. The base is squared only while bits of
/// the exponent remain, which means that when squaring overflows, the result it
/// was headed for would have too, so no false overflow is reported.
fn evaluateIntPower(self: *Interpreter, span: Source.Span, base: i64, exponent: i64) Error!Value {
    if (exponent < 0) return self.raiseFmt(
        span,
        "an Int cannot be raised to the negative power {d}",
        .{exponent},
        "Make the base a Float, as in `2.0 ** -1`, for a fractional result.",
    );

    var result: i64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining > 0) {
        if (remaining & 1 == 1) {
            const product = @mulWithOverflow(result, factor);
            if (product[1] != 0) return self.raisePowerOverflow(span, base, exponent);
            result = product[0];
        }
        remaining >>= 1;
        if (remaining > 0) {
            const square = @mulWithOverflow(factor, factor);
            if (square[1] != 0) return self.raisePowerOverflow(span, base, exponent);
            factor = square[0];
        }
    }
    return .initInt(result);
}

fn raisePowerOverflow(self: *Interpreter, span: Source.Span, base: i64, exponent: i64) Error {
    return self.raiseFmt(
        span,
        "exponentiation of {d} and {d} overflows Int",
        .{ base, exponent },
        integer_range_help,
    );
}

fn evaluateFloatBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: f64,
    right: f64,
) Error!Value {
    switch (operator) {
        .add => return .initFloat(left + right),
        .subtract => return .initFloat(left - right),
        .multiply => return .initFloat(left * right),
        .floor_divide => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            return .initFloat(@floor(left / right));
        },
        .remainder => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // A NaN or infinite operand produces NaN, which @mod already gives.
            return .initFloat(@mod(left, right));
        },
        .power => return .initFloat(std.math.pow(f64, left, right)),
        .divide => unreachable,
    }
}

// Calls.

fn evaluateCall(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Value {
    // `Shapes.area(3)` calls a declaration; `text.upper()` calls a method. The
    // resolver decided which, and recorded it.
    if (self.facts.qualified.get(call.callee)) |key| {
        try self.reach(key, call.callee.span);
        if (self.structs.get(key)) |descriptor| return self.constructStruct(descriptor, call.arguments);
        if (self.functions.contains(key)) return self.callFunction(expression.span, key, call.arguments);
        return self.callValue(expression.span, call);
    }
    // A tuple position holding a block is called through its value.
    if (call.callee.data == .member and call.callee.data.member.position == null) {
        return self.callMethod(expression, call, call.callee.data.member);
    }
    // Anything that is not a plain name is a value that must be evaluated
    // first: a lambda called where it is written, or an element of a list of
    // functions.
    if (call.callee.data != .name) return self.callValue(expression.span, call);

    // The checker has proved the callee is a function: a variable holding one,
    // a program function, which shadows the prelude as any declaration would,
    // or a prelude one.
    const name = call.callee.data.name;
    const key = self.keyOf(name);
    try self.reach(key, call.callee.span);
    if (self.find(name) != null) return self.callValue(expression.span, call);
    if (self.structs.get(key)) |descriptor| return self.constructStruct(descriptor, call.arguments);
    if (self.functions.contains(key)) return self.callFunction(expression.span, key, call.arguments);
    if (std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "input_maybe")) {
        return self.evaluateInput(expression.span, call, std.mem.eql(u8, name, "input_maybe"));
    }
    return self.evaluatePrint(call, std.mem.eql(u8, name, "print"));
}

fn constructStruct(
    self: *Interpreter,
    descriptor: *const Value.StructType,
    arguments: []const *const Ast.Expression,
) Error!Value {
    const fields = try self.evaluateArguments(arguments);
    for (fields, descriptor.fields) |*field, metadata| field.* = widen(field.*, metadata.kind);
    return .{ .data = .{ .struct_value = try self.heap.createStruct(descriptor, fields) } };
}

/// Section 15.2's `input(prompt)` and `input_maybe(prompt)`: writes the prompt,
/// reads one line, and returns it without its line ending. Pressing Enter gives
/// `""`. They differ only at the end of the input, where `input` raises — not
/// catchable yet, as nothing is — and `input_maybe` reports absence (4.5).
fn evaluateInput(self: *Interpreter, span: Source.Span, call: Ast.Expression.Call, maybe: bool) Error!Value {
    if (call.arguments.len == 1) {
        const prompt = try self.evaluate(call.arguments[0]);
        defer self.heap.release(prompt);
        try self.out.writeAll(prompt.data.string.bytes);
    }
    // A prompt has to be seen before the program waits for an answer.
    try self.out.flush();

    var line: std.Io.Writer.Allocating = .init(self.gpa);
    defer line.deinit();
    const length = self.in.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return self.raise(span, "the program's input could not be read", "Check how the program's input is being provided."),
    };
    const at_end = self.in.bufferedLen() == 0;
    if (!at_end) self.in.toss(1); // the newline
    if (at_end and length == 0) {
        // Section 15.2: `input_maybe` reports the end of the input as absence,
        // which is how a program reads until there is nothing left.
        if (maybe) return Value.nothing;
        return self.raise(
            span,
            "`input` reached the end of the input",
            "There are no more lines to read. Use `input_maybe`, which gives `nothing` instead, to read until the input ends.",
        );
    }

    const bytes = std.mem.trimEnd(u8, line.written(), "\r");
    if (!std.unicode.utf8ValidateSlice(bytes)) return self.raise(
        span,
        "the line read by `input` is not valid UTF-8 text",
        "Emerald strings hold Unicode text; check how the input was produced.",
    );
    return self.heap.copyText(bytes);
}

/// Every argument is evaluated before anything is written, as for any other
/// call. Displaying each as it arrived would interleave the output of an
/// argument that prints with the line being built, and an argument that
/// failed would leave half a line behind.
fn evaluatePrint(self: *Interpreter, call: Ast.Expression.Call, newline: bool) Error!Value {
    const values = try self.evaluateArguments(call.arguments);
    defer {
        for (values) |value| self.heap.release(value);
        self.gpa.free(values);
    }

    for (values, 0..) |value, position| {
        // Section 15.2 separates multiple arguments with one space.
        if (position != 0) try self.out.writeAll(" ");
        try value.display(self.out);
    }
    // Section 15.2: `print` ends the line and `write` does not.
    if (newline) try self.out.writeAll("\n");
    // Section 15.2 gives both no result, which is section 4.2's `Nothing`.
    return Value.nothing;
}

/// One call, whatever form it was written in. `captured` is the scope stack the
/// callee runs against: empty for a named function, which can only read the
/// module, and section 7.4's captured scopes for a lambda.
const Callable = struct {
    /// What a stack trace calls it.
    name: []const u8,
    /// A lambda's parameters as written, so section 8.6's `(name, age)` can be
    /// unpacked where it is bound. Empty for a named function, whose
    /// parameters are always plain names.
    parameters: []const Ast.Expression.LambdaParameter = &.{},
    /// Whether `name` is the program's own name for it, which a lambda has not.
    named: bool = true,
    /// The file its body was written in, which is what its bare module-level
    /// names mean and where its own errors are reported.
    file: u32 = 0,
    /// The checked shape, which is where widening comes from (4.4).
    signature: Type.Signature,
    body: Body,
    captured: []const *Environment,

    const Body = union(enum) {
        statements: []const Ast.Statement,
        /// A single-expression lambda, whose value is its result (7.4).
        expression: *const Ast.Expression,
    };
};

/// Section 7.1's calling convention. The checker has already proved arity and
/// argument types, so nothing here checks them again.
fn callFunction(
    self: *Interpreter,
    call_span: Source.Span,
    name: []const u8,
    argument_expressions: []const *const Ast.Expression,
) Error!Value {
    // Arguments evaluate in the caller's scopes before the callee's replace
    // them.
    const arguments = try self.evaluateArguments(argument_expressions);
    defer self.gpa.free(arguments);
    return self.invoke(call_span, self.namedCallable(name), arguments);
}

fn namedCallable(self: *Interpreter, key: []const u8) Callable {
    const declaration = self.functions.get(key).?;
    return .{
        // The name as it was written, not the key: a stack trace should read
        // the way the file reads.
        .name = declaration.name,
        .file = self.facts.owner.get(key) orelse self.file,
        .signature = self.signatures.get(key).?,
        .body = .{ .statements = declaration.body.statements },
        .captured = &.{},
    };
}

/// A call through a value: `double(3)` where `double` holds a lambda, or a
/// lambda called where it is written.
fn callValue(self: *Interpreter, call_span: Source.Span, call: Ast.Expression.Call) Error!Value {
    const callee = try self.evaluate(call.callee);
    defer self.heap.release(callee);
    const arguments = try self.evaluateArguments(call.arguments);
    defer self.gpa.free(arguments);
    return self.invoke(call_span, self.closureCallable(callee.data.closure), arguments);
}

fn closureCallable(self: *Interpreter, closure: *Heap.Closure) Callable {
    return switch (closure.function) {
        .named => |name| self.namedCallable(name),
        .lambda => |expression| .{
            .name = "a block",
            .named = false,
            .file = closure.file,
            .parameters = expression.data.lambda.parameters,
            // The checker recorded the lambda's type where it is written, which
            // is the only place its parameter and result types were known.
            .signature = self.literal_types.get(expression).?.signature.?.*,
            .body = switch (expression.data.lambda.body) {
                .expression => |body| .{ .expression = body },
                .block => |body| .{ .statements = body.statements },
            },
            .captured = closure.captured,
        },
    };
}

/// Runs a callable against already-evaluated arguments, which it takes
/// ownership of.
fn invoke(
    self: *Interpreter,
    call_span: Source.Span,
    callable: Callable,
    arguments: []const Value,
) Error!Value {
    if (self.call_stack.items.len >= max_call_depth) {
        return self.raiseTooMuchRecursion(call_span, callable.name, true);
    }

    // The callee's own block scopes push onto and pop off this list, so by the
    // time it is restored only what it started with is left. The captured
    // scopes are held by the closure, not by this list, so they are left alone.
    const outer_scopes = self.scopes;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > callable.captured.len) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
    }
    try self.scopes.appendSlice(self.gpa, callable.captured);

    const frame = try self.pushScope();
    for (callable.signature.parameter_names, arguments, callable.signature.parameters, 0..) |name, argument, parameter_type, index| {
        // An `Int` passed to a `Float` parameter arrives as a `Float`.
        const kind = kindOf(parameter_type);

        // Section 8.6's `{ (name, age) => ... }`: one argument, unpacked into
        // the names the block's header gave its positions.
        if (index < callable.parameters.len) {
            if (callable.parameters[index].pattern) |pattern| {
                defer self.heap.release(argument);
                try self.unpackInto(pattern, argument, .declare);
                continue;
            }
        }

        // Section 7.4: `_` names nothing, so its argument has nowhere to live.
        if (std.mem.eql(u8, name, "_")) {
            self.heap.release(argument);
            continue;
        }
        try frame.bindings.put(self.gpa, name, .{ .kind = kind, .value = widen(argument, kind) });
    }

    try self.call_stack.append(self.gpa, .{
        .function = callable.name,
        .call_span = call_span,
        // The call is in the caller's file; the body that follows is not.
        .file = self.file,
        .named = callable.named,
    });
    defer _ = self.call_stack.pop();

    const outer_file = self.file;
    self.file = callable.file;
    defer self.file = outer_file;

    const result = switch (callable.body) {
        .expression => |body| try self.evaluate(body),
        .statements => |statements| blk: {
            self.executeAll(statements) catch |err| switch (err) {
                error.Returned => {},
                else => return err,
            };
            const returned = self.return_value orelse Value.nothing;
            self.return_value = null;
            break :blk returned;
        },
    };
    // As with parameters, and including a return type the checker inferred:
    // `return 1` from a function whose returns merged to `Float` yields `1.0`.
    return widen(result, kindOf(callable.signature.return_type));
}

/// Section 4.5's `value.or(fallback)`.
///
/// The fallback is evaluated only when it is needed, the way the `or` operator
/// short-circuits (5.2). `.or(next_ticket())` should not draw a ticket it is
/// going to discard, and nothing else a program can write depends on the
/// argument running.
fn callOr(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const value = try self.evaluate(member.base);
    if (value.data != .nothing) return value;

    // An `Int` standing in for a `Float?` arrives as a `Float`, as anywhere
    // else the checker allowed the widening (4.4).
    const present = self.literal_types.get(expression).?;
    return widen(try self.evaluate(call.arguments[0]), kindOf(present));
}

/// Section 8.5's `each` and section 8.6's `map`.
///
/// The receiver is held for the whole traversal, so the list being visited
/// cannot change underneath it: a block that changes the same variable finds
/// the buffer shared and copies it first, which is section 8.1's value
/// semantics doing exactly what it promises.
/// One value per entry: the member for a set, a `(key, value)` tuple for a
/// dictionary. The caller owns one holder of each.
fn collectItems(self: *Interpreter, map: *const Heap.Map) Error![]Value {
    const items = try self.gpa.alloc(Value, map.entries.items.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| self.heap.release(item);
        self.gpa.free(items);
    }
    while (built < items.len) : (built += 1) {
        const entry = map.entries.items[built];
        items[built] = if (map.is_set)
            Heap.retain(entry.key)
        else
            try self.entryTuple(map, .{
                .hash = entry.hash,
                .key = Heap.retain(entry.key),
                .value = Heap.retain(entry.value),
            });
    }
    return items;
}

/// Section 8.5's dictionary and set methods that only look.
fn readMap(
    self: *Interpreter,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    map: *const Heap.Map,
    arguments: []const Value,
) Error!Value {
    const name = member.name;

    if (std.mem.eql(u8, name, "empty?")) return .initBool(map.count() == 0);

    if (std.mem.eql(u8, name, "contains_key?") or std.mem.eql(u8, name, "contains?")) {
        const key = widen(Heap.retain(arguments[0]), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(call.arguments[0].span, key);
        return .initBool(try Heap.lookupIn(self.gpa, map, hash, key) != null);
    }

    if (std.mem.eql(u8, name, "contains_value?")) {
        for (map.entries.items) |entry| {
            if (try Value.equals(self.gpa, entry.value, arguments[0])) return .initBool(true);
        }
        return .initBool(false);
    }

    if (std.mem.eql(u8, name, "keys")) return self.mapHalf(map, .key);
    if (std.mem.eql(u8, name, "values")) return self.mapHalf(map, .value);

    // `entries`
    const items = try self.collectItems(map);
    defer self.gpa.free(items);
    const list = try self.heap.createList(.tuple, items.len);
    for (items) |item| list.items.appendAssumeCapacity(item);
    return .{ .data = .{ .list = list } };
}

/// Section 8.5's dictionary and set methods that change what they are called
/// on. `map` has already been made safe to change.
fn changeMap(
    self: *Interpreter,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    map: *Heap.Map,
    arguments: []const Value,
) Error!Value {
    const name = member.name;

    if (std.mem.eql(u8, name, "add")) {
        const held = widen(Heap.retain(arguments[0]), map.key_kind);
        const hash = try self.hashKey(call.arguments[0].span, held);
        try self.heap.put(map, hash, held, Value.nothing);
        return Value.nothing;
    }

    if (std.mem.eql(u8, name, "remove")) {
        const key = widen(Heap.retain(arguments[0]), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(call.arguments[0].span, key);
        const removed = try self.heap.removeKey(map, hash, key);
        // A set reports nothing; a dictionary answers with what was there, and
        // absence when the key was not (4.5).
        if (map.is_set) {
            if (removed) |value| self.heap.release(value);
            return Value.nothing;
        }
        return removed orelse Value.nothing;
    }

    // `merge`. The other dictionary's entries are copied first, because merging
    // one into itself would otherwise walk a list growing underneath it.
    const other = arguments[0].data.map;
    const entries = try self.gpa.dupe(Heap.Map.Entry, other.entries.items);
    defer self.gpa.free(entries);
    for (entries) |entry| {
        try self.heap.put(
            map,
            entry.hash,
            Heap.retain(entry.key),
            widen(Heap.retain(entry.value), map.value_kind),
        );
    }
    return Value.nothing;
}

const Half = enum { key, value };

/// Section 8.5's `keys` and `values`, each a list in insertion order.
fn mapHalf(self: *Interpreter, map: *const Heap.Map, half: Half) Error!Value {
    const list = try self.heap.createList(
        if (half == .key) map.key_kind else map.value_kind,
        map.entries.items.len,
    );
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (map.entries.items) |entry| {
        list.items.appendAssumeCapacity(Heap.retain(if (half == .key) entry.key else entry.value));
    }
    return result;
}

fn callHigherOrder(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);

    const callable = self.closureCallable(block.data.closure);

    // Section 8.6: every collection block receives one logical item, and a
    // dictionary's is a `(key, value)` tuple. Building that list up front also
    // gives a dictionary the same "as it was when the loop began" guarantee a
    // list gets for free.
    var built: ?[]Value = null;
    defer if (built) |owned| {
        for (owned) |item| self.heap.release(item);
        self.gpa.free(owned);
    };
    const items: []const Value = if (receiver.data == .map) blk: {
        built = try self.collectItems(receiver.data.map);
        break :blk built.?;
    } else receiver.data.list.items.items;

    const Kind = enum { each, map, find, find_index };
    const kind = std.meta.stringToEnum(Kind, member.name).?;

    const collected: ?*Heap.List = if (kind == .map)
        try self.heap.createList(kindOf(callable.signature.return_type), items.len)
    else
        null;
    const result: Value = if (collected) |list| .{ .data = .{ .list = list } } else Value.nothing;
    errdefer self.heap.release(result);

    for (items, 0..) |item, index| {
        const argument = [_]Value{Heap.retain(item)};
        const produced = try self.invoke(expression.span, callable, &argument);
        if (collected) |list| {
            list.items.appendAssumeCapacity(produced);
            continue;
        }
        if (kind == .each) {
            self.heap.release(produced);
            continue;
        }
        // Searching stops at the first element the block accepts, and reports
        // absence when none does (4.5).
        if (!produced.data.bool) continue;
        return switch (kind) {
            .find => Heap.retain(item),
            else => .initInt(@intCast(index)),
        };
    }
    return result;
}

/// Section 8.5's list methods. The checker has proved the receiver is a list,
/// the method exists, and the arguments fit it.
///
/// A method that changes the list works on the list where it is stored, found
/// the same way an element assignment finds its target: the receiver's indices
/// and then the arguments are evaluated, left to right, and only then is the
/// list walked to and made unique. A method that only reads works on the
/// receiver's value.
fn callMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    // Section 4.5's way out of an optional, and the one method allowed on a
    // value that may be absent.
    if (std.mem.eql(u8, member.name, "or")) return self.callOr(expression, call, member);
    // A block, on a list, a dictionary, or a set.
    if (std.mem.eql(u8, member.name, "each") or std.mem.eql(u8, member.name, "map") or
        std.mem.eql(u8, member.name, "find") or std.mem.eql(u8, member.name, "find_index"))
    {
        return self.callHigherOrder(expression, call, member);
    }
    if (std.mem.eql(u8, member.name, "to_set")) return self.callToSet(member);

    const list_method = Type.list_methods.get(member.name);
    const map_method = Type.map_methods.has(member.name);
    if (list_method == null and !map_method) return self.callValueMethod(expression.span, call, member);

    // Whether it changes what it is called on decides how the receiver is
    // reached, and the receiver is reached exactly once either way. Evaluating
    // it twice would run `input().to_int()` twice, which is a real mistake this
    // file made once.
    const mutates = (list_method != null and list_method.?.mutates) or Type.map_mutators.has(member.name);
    if (!mutates) return self.callReadingMethod(expression, call, member);
    return self.callChangingMethod(expression, call, member);
}

/// A method that only looks at its receiver, which may therefore be any
/// expression at all.
fn callReadingMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const arguments = try self.evaluateArguments(call.arguments);
    defer {
        for (arguments) |argument| self.heap.release(argument);
        self.gpa.free(arguments);
    }

    // `empty?` and `contains?` belong to strings, lists, and sets alike.
    if (receiver.data == .string) {
        return self.stringMethod(expression.span, receiver.data.string.bytes, member.name, arguments);
    }
    if (receiver.data == .map) {
        return self.readMap(call, member, receiver.data.map, arguments);
    }

    const items = receiver.data.list.items.items;
    if (std.mem.eql(u8, member.name, "empty?")) return .initBool(items.len == 0);
    // `contains?`
    for (items) |item| {
        if (try Value.equals(self.gpa, item, arguments[0])) return .initBool(true);
    }
    return .initBool(false);
}

/// A method that changes its receiver. Section 4.3 and 7.1 let the checker
/// allow this only on a name, possibly reached through indices and struct
/// fields, which is exactly what makes the slot holding it reachable. A tuple
/// position never appears on this path: the checker's `walkToPlaceRoot`
/// rejects one before this runs, since a tuple can never be written through.
fn callChangingMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    var path: std.ArrayList(Ast.Step) = .empty;
    defer path.deinit(self.gpa);
    var receiver = member.base;
    while (true) {
        switch (receiver.data) {
            .index => |index| {
                try path.append(self.gpa, .{ .index = index.index });
                receiver = index.base;
            },
            .member => |inner| {
                try path.append(self.gpa, .{ .field = .{ .name = inner.name, .span = inner.name_span } });
                receiver = inner.base;
            },
            else => break,
        }
    }
    std.mem.reverse(Ast.Step, path.items);

    const steps = try self.gpa.alloc(PlaceStep, path.items.len);
    defer {
        for (steps) |step| switch (step) {
            .index => |index| self.heap.release(index.value),
            .field => {},
        };
        self.gpa.free(steps);
    }
    var built: usize = 0;
    errdefer {
        for (steps[built..]) |*step| step.* = .{ .field = "" };
    }
    while (built < steps.len) : (built += 1) {
        steps[built] = switch (path.items[built]) {
            .index => |index_expression| .{ .index = .{ .value = try self.evaluate(index_expression), .span = index_expression.span } },
            .field => |field| .{ .field = field.name },
        };
    }

    const arguments = try self.evaluateArguments(call.arguments);
    defer self.gpa.free(arguments);

    // Section 14.1: a non-entry file initializes on first use, which this is,
    // exactly as a plain assignment already reaches before finding its slot.
    try self.reach(self.keyOf(receiver.data.name), receiver.span);
    const binding = self.find(receiver.data.name).?;
    var slot = &binding.value.?;
    if (steps.len > 0) slot = try self.containerSlot(slot, steps);

    if (slot.data == .map) {
        defer for (arguments) |argument| self.heap.release(argument);
        return self.changeMap(call, member, try self.heap.uniqueMap(slot), arguments);
    }
    const list = try self.heap.unique(slot);
    return self.mutateList(expression.span, list, member.name, arguments);
}

/// Section 8.2's `["red", "green"].to_set()`. Repeats collapse, and the first
/// of each keeps its position, which is what `put` already does.
fn callToSet(self: *Interpreter, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);

    const items = receiver.data.list.items.items;
    const map = try self.heap.createMap(receiver.data.list.element, .nothing, true);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (items) |item| {
        const hash = try self.hashKey(member.base.span, item);
        try self.heap.put(map, hash, Heap.retain(item), Value.nothing);
    }
    return result;
}

/// A method on a string, or `to_string` on a number or `Bool`. None of them
/// changes its receiver.
fn callValueMethod(self: *Interpreter, span: Source.Span, call: Ast.Expression.Call, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const arguments = try self.evaluateArguments(call.arguments);
    defer {
        for (arguments) |argument| self.heap.release(argument);
        self.gpa.free(arguments);
    }

    if (receiver.data == .string) return self.stringMethod(span, receiver.data.string.bytes, member.name, arguments);

    // `to_string` on an `Int`, a `Float`, or a `Bool`: its display.
    var built: std.Io.Writer.Allocating = .init(self.gpa);
    defer built.deinit();
    try receiver.display(&built.writer);
    return .{ .data = .{ .string = try self.heap.createText(try built.toOwnedSlice()) } };
}

/// Section 9.2's string methods, on the receiver's bytes. The checker has
/// proved the method exists and the arguments fit it.
fn stringMethod(self: *Interpreter, span: Source.Span, bytes: []const u8, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        @"empty?",
        @"blank?",
        @"contains?",
        @"starts_with?",
        @"ends_with?",
        trim,
        trim_start,
        trim_end,
        upper,
        lower,
        capitalize,
        reverse,
        repeat,
        replace,
        substring,
        split,
        lines,
        chars,
        index_of,
        to_int,
        to_int_or,
        to_int_maybe,
        to_float,
        to_float_or,
        to_float_maybe,
    };
    const gpa = self.gpa;
    return switch (std.meta.stringToEnum(Method, name).?) {
        .@"empty?" => .initBool(bytes.len == 0),
        .@"blank?" => .initBool(strings.isBlank(bytes)),
        .@"contains?" => .initBool(try strings.contains(gpa, bytes, arguments[0].data.string.bytes)),
        .@"starts_with?" => .initBool(try strings.startsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .@"ends_with?" => .initBool(try strings.endsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .trim => self.heap.copyText(strings.trim(bytes, .both)),
        .trim_start => self.heap.copyText(strings.trim(bytes, .start)),
        .trim_end => self.heap.copyText(strings.trim(bytes, .end)),
        .upper => self.ownedText(try unicode.mapCase(gpa, bytes, .upper)),
        .lower => self.ownedText(try unicode.mapCase(gpa, bytes, .lower)),
        .capitalize => self.ownedText(try strings.capitalize(gpa, bytes)),
        .reverse => self.ownedText(try strings.reverse(gpa, bytes)),
        .repeat => blk: {
            const times = arguments[0].data.int;
            if (times < 0) return self.raiseFmt(
                span,
                "a String cannot be repeated {d} times",
                .{times},
                "Repeat it 0 or more times; 0 gives an empty String.",
            );
            // A result too large to address is as unrepresentable as one too
            // large to allocate.
            const size = std.math.mul(usize, bytes.len, @intCast(times)) catch return error.OutOfMemory;
            const result = try gpa.alloc(u8, size);
            for (0..@intCast(times)) |copy| @memcpy(result[copy * bytes.len ..][0..bytes.len], bytes);
            break :blk self.ownedText(result);
        },
        .replace => blk: {
            const old = arguments[0].data.string.bytes;
            if (old.len == 0) return self.raise(
                span,
                "`replace` needs something to replace, but this is an empty String",
                "Pass the text to find as the first argument.",
            );
            break :blk self.ownedText(try strings.replace(gpa, bytes, old, arguments[1].data.string.bytes));
        },
        .substring => blk: {
            const start = arguments[0].data.int;
            const count: ?i64 = if (arguments.len == 2) arguments[1].data.int else null;
            const slice = strings.substring(bytes, start, count) catch |err| return self.raiseSubstring(span, bytes, start, count, err);
            break :blk self.heap.copyText(slice);
        },
        .split => blk: {
            const separator = arguments[0].data.string.bytes;
            if (separator.len == 0) return self.raise(
                span,
                "`split` needs a separator, but this is an empty String",
                "Use `chars()` to split a String into its characters.",
            );
            break :blk self.stringList(try strings.split(gpa, bytes, separator));
        },
        .lines => self.stringList(try strings.lines(gpa, bytes)),
        .chars => blk: {
            const pieces = try strings.characters(gpa, bytes);
            defer gpa.free(pieces);
            const list = try self.heap.createList(.string, pieces.len);
            const result: Value = .{ .data = .{ .list = list } };
            errdefer self.heap.release(result);
            for (pieces) |piece| list.items.appendAssumeCapacity(try self.heap.copyText(piece));
            break :blk result;
        },
        // Section 9.2: the answer counts characters, so it indexes directly.
        .index_of => blk: {
            const found = try strings.indexOf(gpa, bytes, arguments[0].data.string.bytes);
            break :blk if (found) |index| Value.initInt(index) else Value.nothing;
        },
        // Section 4.4's three forms differ only in what they do when the text
        // does not parse: raise, use the fallback, or report absence.
        .to_int => blk: {
            const parsed = strings.parseInt(bytes);
            if (parsed == .value) break :blk .initInt(parsed.value);
            break :blk self.raiseConversion(span, bytes, "Int", parsed == .out_of_range);
        },
        .to_int_or => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else arguments[0];
        },
        .to_int_maybe => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else Value.nothing;
        },
        .to_float => blk: {
            const parsed = strings.parseFloat(bytes);
            if (parsed == .value) break :blk .initFloat(parsed.value);
            break :blk self.raiseConversion(span, bytes, "Float", parsed == .out_of_range);
        },
        .to_float_or => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else widen(arguments[0], .float);
        },
        .to_float_maybe => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else Value.nothing;
        },
    };
}

fn ownedText(self: *Interpreter, bytes: []u8) Error!Value {
    return .{ .data = .{ .string = try self.heap.createText(bytes) } };
}

/// A list of strings from pieces the caller allocated, which the strings take.
fn stringList(self: *Interpreter, pieces: [][]u8) Error!Value {
    defer self.gpa.free(pieces);
    var taken: usize = 0;
    errdefer for (pieces[taken..]) |piece| self.gpa.free(piece);

    const list = try self.heap.createList(.string, pieces.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (pieces) |piece| {
        taken += 1;
        list.items.appendAssumeCapacity(.{ .data = .{ .string = try self.heap.createText(piece) } });
    }
    return result;
}

/// Section 9.4's strict parsing, which raises a conversion error. Catching it
/// arrives with section 13; until then `to_int_or` is the way to recover.
fn raiseConversion(self: *Interpreter, span: Source.Span, bytes: []const u8, comptime type_name: []const u8, out_of_range: bool) Error {
    const excerpt = if (bytes.len > 40) "the text" else try std.fmt.allocPrint(self.arena, "\"{s}\"", .{bytes});
    if (out_of_range) return self.raiseFmt(
        span,
        "{s} is outside the range of " ++ type_name,
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807. `to_int_or(0)` gives a fallback instead of an error."
        else
            "The number is too large for a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
    return self.raiseFmt(
        span,
        "{s} is not " ++ (if (std.mem.eql(u8, type_name, "Int")) "a whole number" else "a number"),
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "Only digits, with an optional sign and surrounding spaces, convert to an Int. `to_int_or(0)` gives a fallback instead of an error."
        else
            "Only a number such as `2.5` or `3`, with an optional sign and surrounding spaces, converts to a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
}

/// Section 9.1: substring bounds are errors rather than being clamped.
fn raiseSubstring(self: *Interpreter, span: Source.Span, bytes: []const u8, start: i64, count: ?i64, err: strings.SubstringError) Error {
    const total = unicode.graphemeCount(bytes);
    return switch (err) {
        error.NegativeStart => self.raiseFmt(span, "a substring cannot start at {d}", .{start}, "Start at 0 or later."),
        error.NegativeCount => self.raiseFmt(span, "a substring cannot have {d} characters", .{count.?}, "Ask for 0 or more characters."),
        error.StartPastEnd => self.raiseFmt(
            span,
            "a substring cannot start at {d} in a String of {d} character{s}",
            .{ start, total, if (total == 1) "" else "s" },
            "Start at most at the String's `count`, which gives an empty String.",
        ),
        error.CountPastEnd => self.raiseFmt(
            span,
            "a substring of {d} character{s} from {d} runs past the end of a String of {d}",
            .{ count.?, if (count.? == 1) "" else "s", start, total },
            "Ask for fewer characters, or leave the count out to take the rest of the String.",
        ),
    };
}

/// Runs one mutating list method. Arguments are owned: one that is stored is
/// taken by the list, and the rest are released here.
fn mutateList(self: *Interpreter, span: Source.Span, list: *Heap.List, name: []const u8, arguments: []const Value) Error!Value {
    const items = &list.items;
    const Method = enum { append, insert, remove, remove_all, remove_at, remove_first, remove_last, clear };
    switch (std.meta.stringToEnum(Method, name).?) {
        .append => try items.append(self.gpa, widen(arguments[0], list.element)),
        .insert => {
            const index = arguments[0].data.int;
            if (index < 0 or index > items.items.len) {
                const count = items.items.len;
                const help = try std.fmt.allocPrint(
                    self.arena,
                    "Insert at 0 through {d}. Inserting at {d} adds to the end.",
                    .{ count, count },
                );
                return self.raiseFmt(
                    span,
                    "cannot insert at index {d} in a list of {d} element{s}",
                    .{ index, count, if (count == 1) "" else "s" },
                    help,
                );
            }
            try items.insert(self.gpa, @intCast(index), widen(arguments[1], list.element));
        },
        .remove => {
            defer self.heap.release(arguments[0]);
            for (items.items, 0..) |item, position| {
                if (!try Value.equals(self.gpa, item, arguments[0])) continue;
                self.heap.release(items.orderedRemove(position));
                break;
            }
        },
        .remove_all => {
            defer self.heap.release(arguments[0]);
            var kept: usize = 0;
            for (items.items) |item| {
                if (try Value.equals(self.gpa, item, arguments[0])) {
                    self.heap.release(item);
                } else {
                    items.items[kept] = item;
                    kept += 1;
                }
            }
            items.shrinkRetainingCapacity(kept);
        },
        .remove_at => {
            const position = try self.checkIndex(list, arguments[0].data.int, span);
            return items.orderedRemove(position);
        },
        .remove_first, .remove_last => {
            if (items.items.len == 0) return self.raise(
                span,
                "cannot remove an element from an empty list",
                "Check `empty?()` first.",
            );
            return if (std.mem.eql(u8, name, "remove_first")) items.orderedRemove(0) else items.pop().?;
        },
        .clear => {
            for (items.items) |item| self.heap.release(item);
            items.clearRetainingCapacity();
        },
    }
    return Value.nothing;
}

/// Section 5.2: arguments evaluate left to right, every one of them before the
/// call itself happens. The caller frees the result.
fn evaluateArguments(self: *Interpreter, expressions: []const *const Ast.Expression) Error![]Value {
    const values = try self.gpa.alloc(Value, expressions.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| self.heap.release(value);
        self.gpa.free(values);
    }
    for (expressions, values) |expression, *value| {
        value.* = try self.evaluate(expression);
        initialized += 1;
    }
    return values;
}

// Raising.

const integer_range_help =
    "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807.";

/// Every runtime error carries the calls active when it was raised, innermost
/// first, which is section 13.2's stack trace.
fn raise(self: *Interpreter, span: Source.Span, message: []const u8, help: []const u8) Error {
    const trace = try self.arena.alloc(Diagnostic.Frame, self.call_stack.items.len);
    for (trace, 0..) |*frame, index| {
        frame.* = self.call_stack.items[self.call_stack.items.len - 1 - index];
    }
    self.failure = .{ .message = message, .span = span, .help = help, .trace = trace, .file = self.file };
    return error.Raised;
}

fn raiseFmt(
    self: *Interpreter,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error {
    const message = try std.fmt.allocPrint(self.arena, message_format, message_args);
    return self.raise(span, message, help);
}

fn raiseUnassigned(self: *Interpreter, span: Source.Span, name: []const u8) Error {
    const help = try std.fmt.allocPrint(self.arena, "Assign `{s}` before reading it.", .{name});
    return self.raise(span, try std.fmt.allocPrint(self.arena, "`{s}` is not assigned yet", .{name}), help);
}

fn raiseDivisionByZero(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
) Error {
    return self.raiseFmt(
        span,
        "{s} by zero",
        .{operator.describe()},
        "Check the divisor before dividing. Division by zero has no result for either numeric type.",
    );
}

/// Section 7.2: crossing the limit raises rather than exhausting the host
/// stack, and the trace attached by `raise` summarizes the repeating frames.
/// `at_limit` distinguishes reaching the 1,000-call guarantee from running out
/// of stack before it, which only a pathologically nested body can do.
fn raiseTooMuchRecursion(self: *Interpreter, span: Source.Span, name: []const u8, at_limit: bool) Error {
    return self.raiseFmt(
        span,
        "too much recursion calling `{s}`",
        .{name},
        if (at_limit)
            "Emerald supports at least 1,000 active calls. Check that the recursion has a case that stops it."
        else
            "These calls nest too deeply for the stack available. Check that the recursion has a case that stops it.",
    );
}

/// Callers check `isNumber` first, so a `Bool` never reaches here.
fn toFloat(value: Value) f64 {
    return switch (value.data) {
        .int => |number| @floatFromInt(number),
        .float => |number| number,
        .nothing, .bool, .string, .list, .tuple, .map, .closure, .struct_value => unreachable,
    };
}
