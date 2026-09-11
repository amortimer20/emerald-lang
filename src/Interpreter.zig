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
//!   `**`         always `Float`, even for integer operands
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
const Diagnostic = @import("Diagnostic.zig");
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

const Error = error{ Raised, Returned } || RunError;

arena: std.mem.Allocator,
source: *const Source,
out: *std.Io.Writer,
failure: ?Diagnostic = null,

/// Top-level bindings. A function sees these, and it sees them as they are
/// when it runs; the checker has already proved that everything a call reads
/// is assigned by then.
module: Scope = .empty,
/// Block scopes at the top level, or the current function's own scopes
/// during a call, innermost last. A call replaces this stack for its duration,
/// so a function never sees the block-local names of whoever called it.
scopes: std.ArrayList(Scope) = .empty,

functions: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
/// What the checker proved about each function, including return types it
/// inferred, which are needed to widen results the way it allowed.
signatures: *const Type.Signatures,
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
    out: *std.Io.Writer,
    stack: StackLimit,
) RunError!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var interpreter: Interpreter = .{
        .arena = arena_state.allocator(),
        .source = source,
        .out = out,
        .signatures = signatures,
        .stack = stack,
    };

    // Hoisted, matching the resolver and checker.
    for (program.statements) |statement| {
        if (statement.data != .function_declaration) continue;
        const function = statement.data.function_declaration;
        try interpreter.functions.put(interpreter.arena, function.name, function);
    }

    interpreter.executeAll(program.statements) catch |err| switch (err) {
        error.Raised => {},
        // The checker rejects `return` outside a function, and section 14.1's
        // top-level `return` is deferred.
        error.Returned => unreachable,
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
    try self.scopes.append(self.arena, .empty);
    defer _ = self.scopes.pop();
    try self.executeAll(block.statements);
}

fn execute(self: *Interpreter, statement: Ast.Statement) Error!void {
    try self.guardStack(statement.span);

    switch (statement.data) {
        .expression => |expression| _ = try self.evaluate(expression),

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

            const current = if (self.scopes.items.len > 0)
                &self.scopes.items[self.scopes.items.len - 1]
            else
                &self.module;
            try current.put(self.arena, declaration.name, .{
                .kind = kind,
                .value = if (initial) |value| widen(value, kind) else null,
            });
        },

        .assignment => |assignment| {
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
            slot.value = widen(value, slot.kind);
        },

        .conditional => |conditional| try self.executeConditional(conditional),

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
        .name => |name| if (self.find(name)) |slot|
            slot.value orelse self.raiseUnassigned(expression.span, name)
        else
            // The checker proves every name read here is bound and assigned,
            // so this is a safety net rather than a language rule.
            self.raiseUnassigned(expression.span, name),
        .unary => |unary| self.evaluateUnary(expression, unary),
        .binary => |binary| self.evaluateBinary(expression, binary),
        .logical => |logical| self.evaluateLogical(logical),
        .comparison => |comparison| self.evaluateComparison(expression, comparison),
        .call => |call| self.evaluateCall(expression, call),
    };
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
    var left = try self.evaluate(comparison.operands[0]);

    for (comparison.operators, comparison.operands[1..]) |operator, operand_node| {
        const right = try self.evaluate(operand_node);

        const holds = if (Value.order(left, right)) |ordering|
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

        if (!holds) return .initBool(false);
        left = right;
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
            .nothing, .bool => return self.raiseFmt(
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

    // These two always produce a Float regardless of operand types.
    switch (operator) {
        .divide => {
            const divisor = toFloat(right);
            if (divisor == 0) return self.raiseDivisionByZero(span, operator);
            return .initFloat(toFloat(left) / divisor);
        },
        .power => return .initFloat(std.math.pow(f64, toFloat(left), toFloat(right))),
        else => {},
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
        .divide, .power => unreachable, // handled before operand kinds matter
    }
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
        .divide, .power => unreachable,
    }
}

// Calls.

fn evaluateCall(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Value {
    // The checker has proved the callee is a function: a program function,
    // which shadows the prelude as any declaration would, or `print`.
    const name = call.callee.data.name;
    if (self.functions.contains(name)) return self.callFunction(expression.span, name, call.arguments);
    return self.evaluatePrint(call);
}

fn evaluatePrint(self: *Interpreter, call: Ast.Expression.Call) Error!Value {
    for (call.arguments, 0..) |argument, position| {
        const value = try self.evaluate(argument);
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
    // Arguments evaluate in the caller's scopes, left to right per section 5.2,
    // before the callee's replace them.
    const arguments = try self.arena.alloc(Value, argument_expressions.len);
    for (argument_expressions, arguments) |expression, *value| {
        value.* = try self.evaluate(expression);
    }

    if (self.call_stack.items.len >= max_call_depth) {
        return self.raiseTooMuchRecursion(call_span, name, true);
    }

    const function = self.functions.get(name).?;
    const signature = self.signatures.get(name).?;

    const outer_scopes = self.scopes;
    self.scopes = .empty;
    defer self.scopes = outer_scopes;

    try self.scopes.append(self.arena, .empty);
    const frame = &self.scopes.items[0];
    for (function.parameters, arguments, signature.parameters) |parameter, argument, parameter_type| {
        // An `Int` passed to a `Float` parameter arrives as a `Float`.
        const kind = kindOf(parameter_type);
        try frame.put(self.arena, parameter.name, .{ .kind = kind, .value = widen(argument, kind) });
    }

    try self.call_stack.append(self.arena, .{ .function = name, .call_span = call_span });
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
        .nothing, .bool => unreachable,
    };
}
