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
const Source = @import("Source.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");

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

/// A name and the kind it holds.
///
/// The kind is carried because section 4.4's widening has to actually happen,
/// not merely be permitted. The checker accepts `var rate: Float = 1` because an
/// `Int` is assignable to a `Float`; if the interpreter then stored the `Int`,
/// the static type and the runtime value would disagree and `rate` would print
/// as `1` rather than `1.0`.
const Binding = struct {
    kind: Value.Kind,
    value: ?Value,
};

const Scope = std.StringHashMapUnmanaged(Binding);

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
source: *const Source,
out: *std.Io.Writer,
failure: ?Diagnostic = null,

/// Top-level bindings, from `arena`. A function sees these, and it sees them
/// as they are when it runs; the checker has already proved that everything a
/// call reads is assigned by then.
module: Scope = .empty,
/// Block scopes at the top level, or the current function's own scopes
/// during a call, innermost last, from `gpa`. A call replaces this stack for its duration,
/// so a function never sees the block-local names of whoever called it.
scopes: std.ArrayList(Scope) = .empty,
/// Emptied scopes kept for reuse. A loop body opens a scope every iteration,
/// and taking one from here instead of allocating makes a loop that declares a
/// local cost no allocation at all once it is running.
spare_scopes: std.ArrayList(Scope) = .empty,

functions: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
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
    source: *const Source,
    program: Ast.Program,
    signatures: *const Type.Signatures,
    literal_types: *const Checker.LiteralTypes,
    out: *std.Io.Writer,
    stack: StackLimit,
) RunError!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var interpreter: Interpreter = .{
        .arena = arena_state.allocator(),
        .gpa = gpa,
        .source = source,
        .out = out,
        .signatures = signatures,
        .literal_types = literal_types,
        .heap = .init(gpa),
        .stack = stack,
    };
    // Whatever the counts did not reclaim, including lists still held by
    // module bindings and anything an error skipped releasing.
    defer interpreter.heap.deinit();

    // Hoisted, matching the resolver and checker.
    for (program.statements) |statement| {
        if (statement.data != .function_declaration) continue;
        const function = statement.data.function_declaration;
        try interpreter.functions.put(interpreter.arena, function.name, function);
    }

    // Each block and call frees its own scope as it ends, including while an
    // error unwinds through it, so only the lists themselves are left.
    defer interpreter.scopes.deinit(gpa);
    defer interpreter.call_stack.deinit(gpa);
    defer {
        for (interpreter.spare_scopes.items) |*scope| scope.deinit(gpa);
        interpreter.spare_scopes.deinit(gpa);
    }

    interpreter.executeAll(program.statements) catch |err| switch (err) {
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

/// Section 6.1 gives every block its own scope, and a local declared inside does
/// not leak out.
fn executeBlock(self: *Interpreter, block: Ast.Block) Error!void {
    _ = try self.pushScope();
    defer self.popScope();
    try self.executeAll(block.statements);
}

fn pushScope(self: *Interpreter) Error!*Scope {
    var scope = self.spare_scopes.pop() orelse Scope.empty;
    self.scopes.append(self.gpa, scope) catch |err| {
        scope.deinit(self.gpa);
        return err;
    };
    return &self.scopes.items[self.scopes.items.len - 1];
}

/// Keeps the scope's table for the next block, emptied, after releasing
/// everything its bindings held.
fn popScope(self: *Interpreter) void {
    var scope = self.scopes.pop().?;
    var bindings = scope.valueIterator();
    while (bindings.next()) |binding| {
        if (binding.value) |value| self.heap.release(value);
    }
    scope.clearRetainingCapacity();
    self.spare_scopes.append(self.gpa, scope) catch scope.deinit(self.gpa);
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
            const current = if (in_block) &self.scopes.items[self.scopes.items.len - 1] else &self.module;
            try current.put(if (in_block) self.gpa else self.arena, declaration.name, .{
                .kind = kind,
                .value = if (initial) |value| widen(value, kind) else null,
            });
        },

        .assignment => |assignment| {
            if (assignment.indices.len > 0) return self.assignElement(assignment);
            const slot = self.find(assignment.name).?;
            const value = if (assignment.operation) |operation| blk: {
                // Section 5.3 lowers a compound assignment through the same
                // operation as its binary form. The current value is read once.
                const current = slot.value orelse return self.raiseUnassigned(
                    assignment.name_span,
                    assignment.name,
                );
                const right = try self.evaluate(assignment.value);
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

        .return_statement => |return_statement| {
            self.return_value = if (return_statement.value) |value|
                try self.evaluate(value)
            else
                Value.nothing;
            return error.Returned;
        },
    }
}

/// `scores[i] = value`, or `grid[i][j] += 1`.
///
/// The indices are evaluated first and then the value, left to right as
/// section 5.2 requires. Only then is the list walked, because evaluating the
/// value can change it: a function it calls can append to the same list. Each
/// list on the way down is made unique first, which is copy-on-write: a list
/// another binding also holds is copied before anything in it changes.
fn assignElement(self: *Interpreter, assignment: Ast.Assignment) Error!void {
    const indices = try self.gpa.alloc(i64, assignment.indices.len);
    defer self.gpa.free(indices);
    for (assignment.indices, indices) |expression, *index| {
        index.* = (try self.evaluate(expression)).data.int;
    }

    const binding = self.find(assignment.name).?;
    const root = &binding.value.?;

    if (assignment.operation) |operation| {
        // Section 5.2: the current value is read once, before the right side.
        const current = (try self.elementSlot(root, indices, assignment.indices)).slot.*;
        const right = try self.evaluate(assignment.value);
        const result = try self.applyBinary(assignment.target_span, operation, current, right);
        const place = try self.elementSlot(root, indices, assignment.indices);
        place.slot.* = widen(result, place.list.element);
        return;
    }

    const value = try self.evaluate(assignment.value);
    const place = try self.elementSlot(root, indices, assignment.indices);
    self.heap.release(place.slot.*);
    place.slot.* = widen(value, place.list.element);
}

const Place = struct { list: *Heap.List, slot: *Value };

/// Walks from the list in `root` through `indices` to one element, making each
/// list on the way safe to change and checking every index against it.
fn elementSlot(
    self: *Interpreter,
    root: *Value,
    indices: []const i64,
    expressions: []const *const Ast.Expression,
) Error!Place {
    var slot = root;
    var list: *Heap.List = undefined;
    for (indices, expressions) |index, expression| {
        list = try self.heap.unique(slot);
        const position = try self.checkIndex(list, index, expression.span);
        slot = &list.items.items[position];
    }
    return .{ .list = list, .slot = slot };
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

/// Section 6.4's `for` over a range. The endpoints are evaluated once, before
/// the first iteration, and a range only counts upward, so one whose start is
/// past its end visits nothing.
///
/// The loop stops by comparing with the last value rather than by stepping past
/// it, because stepping past `9223372036854775807` would overflow.
fn executeFor(self: *Interpreter, loop: Ast.For) Error!void {
    if (loop.iterable.data != .range) return self.executeForList(loop);

    const range = loop.iterable.data.range;
    const start = (try self.evaluate(range.start)).data.int;
    const end = (try self.evaluate(range.end)).data.int;

    if (start > end or (!range.inclusive and start == end)) return;
    const last = if (range.inclusive) end else end - 1;

    var current = start;
    while (try self.executeIteration(loop, .initInt(current))) {
        if (current == last) return;
        current += 1;
    }
}

/// Section 8.4: the loop visits the list as it was when the loop began. Holding
/// the buffer for the whole loop is what guarantees it: a change the body makes
/// through the list's own binding finds the buffer shared and copies it first.
fn executeForList(self: *Interpreter, loop: Ast.For) Error!void {
    const iterable = try self.evaluate(loop.iterable);
    defer self.heap.release(iterable);

    for (iterable.data.list.items.items) |item| {
        if (!try self.executeIteration(loop, Heap.retain(item))) return;
    }
}

/// One pass through a `for` body with the loop variable bound to `value`, in a
/// scope of its own, which is what makes the binding fresh every iteration.
/// `value` is owned: the binding takes it, and `_` releases it. False when a
/// `break` ended the loop.
fn executeIteration(self: *Interpreter, loop: Ast.For, value: Value) Error!bool {
    const scope = try self.pushScope();
    defer self.popScope();

    if (std.mem.eql(u8, loop.name, "_")) {
        self.heap.release(value);
    } else {
        scope.put(self.gpa, loop.name, .{ .kind = value.kind(), .value = value }) catch |err| {
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
    if (annotation.element != null) return .list;
    return kindOf(Type.fromName(annotation.name) orelse .invalid);
}

/// The runtime kind for a checked type. `.invalid` never reaches a program that
/// passed checking.
fn kindOf(checked: Type) Value.Kind {
    return switch (checked.kind) {
        .nothing, .invalid => .nothing,
        .bool => .bool,
        .int => .int,
        .float => .float,
        .list => .list,
    };
}

fn find(self: *Interpreter, name: []const u8) ?*Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].getPtr(name)) |slot| return slot;
    }
    return self.module.getPtr(name);
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
        .name => |name| if (self.find(name)) |slot|
            (if (slot.value) |value| Heap.retain(value) else self.raiseUnassigned(expression.span, name))
        else
            // The checker proves every name read here is bound and assigned,
            // so this is a safety net rather than a language rule.
            self.raiseUnassigned(expression.span, name),
        .unary => |unary| self.evaluateUnary(expression, unary),
        .binary => |binary| self.evaluateBinary(expression, binary),
        .logical => |logical| self.evaluateLogical(logical),
        .comparison => |comparison| self.evaluateComparison(expression, comparison),
        .call => |call| self.evaluateCall(expression, call),
        // The checker allows a range only as what a `for` loop visits, which
        // `executeFor` reads directly.
        .range => unreachable,
        .list_literal => |elements| self.evaluateList(expression, elements),
        .index => |index| self.evaluateIndex(expression, index),
        // `count` is the only property so far; the checker allows nothing else.
        .member => |member| blk: {
            const base = try self.evaluate(member.base);
            defer self.heap.release(base);
            break :blk .initInt(@intCast(base.data.list.items.items.len));
        },
    };
}

/// Section 8.2. The checker recorded the literal's type, which says whether
/// whole numbers in it are to be stored as `Float`s.
fn evaluateList(self: *Interpreter, expression: *const Ast.Expression, elements: []const *const Ast.Expression) Error!Value {
    const checked = self.literal_types.get(expression).?;
    const element = kindOf(checked.element.?.*);

    const list = try self.heap.createList(element, elements.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (elements) |item| list.items.appendAssumeCapacity(widen(try self.evaluate(item), element));
    return result;
}

fn evaluateIndex(self: *Interpreter, expression: *const Ast.Expression, index: Ast.Expression.Index) Error!Value {
    const base = try self.evaluate(index.base);
    defer self.heap.release(base);
    const position = (try self.evaluate(index.index)).data.int;
    const list = base.data.list;
    const at = try self.checkIndex(list, position, expression.span);
    return Heap.retain(list.items.items[at]);
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
            Value.equals(left, right) == (operator == .equal)
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
            .nothing, .bool, .list => return self.raiseFmt(
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
    const right = try self.evaluate(binary.right);
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
    if (call.callee.data == .member) return self.callMethod(expression, call, call.callee.data.member);

    // The checker has proved the callee is a function: a program function,
    // which shadows the prelude as any declaration would, or `print`.
    const name = call.callee.data.name;
    if (self.functions.contains(name)) return self.callFunction(expression.span, name, call.arguments);
    return self.evaluatePrint(call);
}

/// Every argument is evaluated before anything is written, as for any other
/// call. Displaying each as it arrived would interleave the output of an
/// argument that prints with the line being built, and an argument that
/// failed would leave half a line behind.
fn evaluatePrint(self: *Interpreter, call: Ast.Expression.Call) Error!Value {
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
    try self.out.writeAll("\n");
    // Section 15.2 gives `print` no result, which is section 4.2's `Nothing`.
    return Value.nothing;
}

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

    if (self.call_stack.items.len >= max_call_depth) {
        return self.raiseTooMuchRecursion(call_span, name, true);
    }

    const function = self.functions.get(name).?;
    const signature = self.signatures.get(name).?;

    // The function's own block scopes push onto and pop off this list, so by
    // the time it is restored only the parameter scope is left in it.
    const outer_scopes = self.scopes;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
    }

    const frame = try self.pushScope();
    for (function.parameters, arguments, signature.parameters) |parameter, argument, parameter_type| {
        // An `Int` passed to a `Float` parameter arrives as a `Float`.
        const kind = kindOf(parameter_type);
        try frame.put(self.gpa, parameter.name, .{ .kind = kind, .value = widen(argument, kind) });
    }

    try self.call_stack.append(self.gpa, .{ .function = name, .call_span = call_span });
    defer _ = self.call_stack.pop();

    self.executeAll(function.body.statements) catch |err| switch (err) {
        error.Returned => {},
        else => return err,
    };

    const result = self.return_value orelse Value.nothing;
    self.return_value = null;
    // As with parameters, and including a return type the checker inferred:
    // `return 1` from a function whose returns merged to `Float` yields `1.0`.
    return widen(result, kindOf(signature.return_type));
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
    const method = Type.list_methods.get(member.name).?;
    if (!method.mutates) {
        const receiver = try self.evaluate(member.base);
        defer self.heap.release(receiver);
        const arguments = try self.evaluateArguments(call.arguments);
        defer {
            for (arguments) |argument| self.heap.release(argument);
            self.gpa.free(arguments);
        }
        const items = receiver.data.list.items.items;
        if (std.mem.eql(u8, member.name, "empty?")) return .initBool(items.len == 0);
        // `contains?`
        for (items) |item| {
            if (Value.equals(item, arguments[0])) return .initBool(true);
        }
        return .initBool(false);
    }

    // The receiver is a name, possibly indexed: the checker allows a mutating
    // method on nothing else.
    var path: std.ArrayList(*const Ast.Expression) = .empty;
    defer path.deinit(self.gpa);
    var receiver = member.base;
    while (receiver.data == .index) {
        try path.append(self.gpa, receiver.data.index.index);
        receiver = receiver.data.index.base;
    }
    std.mem.reverse(*const Ast.Expression, path.items);

    const indices = try self.gpa.alloc(i64, path.items.len);
    defer self.gpa.free(indices);
    for (path.items, indices) |index_expression, *index| index.* = (try self.evaluate(index_expression)).data.int;

    const arguments = try self.evaluateArguments(call.arguments);
    defer self.gpa.free(arguments);

    const binding = self.find(receiver.data.name).?;
    var slot = &binding.value.?;
    if (indices.len > 0) slot = (try self.elementSlot(slot, indices, path.items)).slot;
    const list = try self.heap.unique(slot);
    return self.mutateList(expression.span, list, member.name, arguments);
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
                if (!Value.equals(item, arguments[0])) continue;
                self.heap.release(items.orderedRemove(position));
                break;
            }
        },
        .remove_all => {
            defer self.heap.release(arguments[0]);
            var kept: usize = 0;
            for (items.items) |item| {
                if (Value.equals(item, arguments[0])) {
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
    errdefer self.gpa.free(values);
    for (expressions, values) |expression, *value| value.* = try self.evaluate(expression);
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
    self.failure = .{ .message = message, .span = span, .help = help, .trace = trace };
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
        .nothing, .bool, .list => unreachable,
    };
}
