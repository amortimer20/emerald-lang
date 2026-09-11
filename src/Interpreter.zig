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

    for (program.statements) |statement| {
        interpreter.execute(statement) catch |err| switch (err) {
            error.Raised => break,
            else => return err,
        };
    }

    return .{ .arena_state = arena_state, .failure = interpreter.failure };
}

fn execute(self: *Interpreter, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| _ = try self.evaluate(expression),
    }
}

fn evaluate(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    return switch (expression.data) {
        .int_literal => |value| .initInt(value),
        .float_literal => |value| .initFloat(value),
        .name => |name| self.raiseFmt(
            expression.span,
            "`{s}` is not defined",
            .{name},
            "Check the spelling, or declare it before this line.",
        ),
        .unary => |unary| self.evaluateUnary(expression, unary),
        .binary => |binary| self.evaluateBinary(expression, binary),
        .call => |call| self.evaluateCall(expression, call),
    };
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
    const span = expression.span;

    // These two always produce a Float regardless of operand types.
    switch (binary.operator) {
        .divide => {
            const divisor = toFloat(right);
            if (divisor == 0) return self.raiseDivisionByZero(span, binary.operator);
            return .initFloat(toFloat(left) / divisor);
        },
        .power => return .initFloat(std.math.pow(f64, toFloat(left), toFloat(right))),
        else => {},
    }

    const both_int = left.data == .int and right.data == .int;
    if (!both_int) return self.evaluateFloatBinary(span, binary.operator, toFloat(left), toFloat(right));

    return self.evaluateIntBinary(span, binary.operator, left.data.int, right.data.int);
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
    return .initInt(0); // `print` has no result; nothing can observe this yet.
}

fn toFloat(value: Value) f64 {
    return switch (value.data) {
        .int => |number| @floatFromInt(number),
        .float => |number| number,
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
