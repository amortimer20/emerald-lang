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

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Source = @import("Source.zig");
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

arena: std.mem.Allocator,
source: *const Source,
out: *std.Io.Writer,
failure: ?Diagnostic = null,
/// One map per lexical scope, innermost last. The resolver has already proven
/// every name reaches a binding, so lookups here cannot miss.
scopes: std.ArrayList(Scope) = .empty,

const Scope = std.StringHashMapUnmanaged(Value);

const Error = error{Raised} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn run(
    gpa: std.mem.Allocator,
    source: *const Source,
    program: Ast.Program,
    out: *std.Io.Writer,
) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    var interpreter: Interpreter = .{
        .arena = arena_state.allocator(),
        .source = source,
        .out = out,
    };

    try interpreter.scopes.append(interpreter.arena, .empty);
    interpreter.executeAll(program.statements) catch |err| switch (err) {
        error.Raised => {},
        else => return err,
    };

    const failure = interpreter.failure;
    return .{ .arena_state = arena_state, .failure = failure };
}

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
    switch (statement.data) {
        .expression => |expression| _ = try self.evaluate(expression),

        .declaration => |declaration| {
            const value = try self.evaluate(declaration.initializer);
            const current = &self.scopes.items[self.scopes.items.len - 1];
            try current.put(self.arena, declaration.name, value);
        },

        .assignment => |assignment| {
            const slot = self.find(assignment.name).?;
            const value = if (assignment.operation) |operation|
                // Section 5.3 lowers a compound assignment through the same
                // operation as its binary form. The current value is read once.
                try self.applyBinary(statement.span, operation, slot.*, try self.evaluate(assignment.value))
            else
                try self.evaluate(assignment.value);
            slot.* = value;
        },

        .conditional => |conditional| try self.executeConditional(statement, conditional),
    }
}

fn executeConditional(
    self: *Interpreter,
    statement: Ast.Statement,
    conditional: Ast.If,
) Error!void {
    _ = statement;
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

fn find(self: *Interpreter, name: []const u8) ?*Value {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].getPtr(name)) |slot| return slot;
    }
    return null;
}

fn evaluate(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    return switch (expression.data) {
        .int_literal => |value| .initInt(value),
        .float_literal => |value| .initFloat(value),
        .bool_literal => |value| .initBool(value),
        .nothing_literal => Value.nothing,
        .name => |name| if (self.find(name)) |slot| slot.* else self.raise(
            expression.span,
            "this name cannot be used as a value",
            "`print` is a prelude function and can only be called.",
        ),
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

fn evaluateCall(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Value {
    // `print` is the only callable that exists. Ordinary functions, and the name
    // resolution that would find them, arrive with their own slices.
    if (call.callee.data != .name or !std.mem.eql(u8, call.callee.data.name, "print")) {
        return self.raise(
            call.callee.span,
            "this is not something that can be called",
            "`print` is the only function available so far.",
        );
    }

    for (call.arguments, 0..) |argument, position| {
        const value = try self.evaluate(argument);
        // Section 15.2 separates multiple arguments with one space.
        if (position != 0) try self.out.writeAll(" ");
        try value.display(self.out);
    }
    try self.out.writeAll("\n");

    _ = expression;
    // Section 15.2 gives `print` no result, which is section 4.2's `Nothing`.
    return Value.nothing;
}

/// Callers check `isNumber` first, so a `Bool` never reaches here.
fn toFloat(value: Value) f64 {
    return switch (value.data) {
        .int => |number| @floatFromInt(number),
        .float => |number| number,
        .nothing, .bool => unreachable,
    };
}

const integer_range_help =
    "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807.";

fn raise(self: *Interpreter, span: Source.Span, message: []const u8, help: []const u8) Error {
    self.failure = .{ .message = message, .span = span, .help = help };
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
