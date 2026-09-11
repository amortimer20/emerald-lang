//! Static type checking and flow analysis.
//!
//! Section 4.1 requires every expression to have a type before execution, locals
//! to be inferred from their initializers, an uninitialized variable to carry an
//! explicit type, and definite assignment to be proved through control flow
//! rather than papered over with a default value.
//!
//! This runs after name resolution, so every name is known to reach a binding
//! and the work here is only about types and assignment state.
//!
//! Errors do not cascade. An expression whose type could not be determined gets
//! `Type.invalid`, which is compatible with everything, so one mistake produces
//! one diagnostic rather than one per enclosing expression. Section 17.2 asks
//! for exactly that.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Resolver = @import("Resolver.zig");
const Source = @import("Source.zig");
const Type = @import("Type.zig");

const Checker = @This();

pub const Checked = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn ok(self: Checked) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Checked) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

const Binding = struct {
    type: Type,
    /// Section 4.1: a variable declared without an initializer stays unassigned
    /// until control flow proves otherwise, and reading it before then is an
    /// error.
    assigned: bool,
};

const Scope = std.StringHashMapUnmanaged(Binding);

/// Stated rather than inferred: the walk functions are mutually recursive.
const Error = std.mem.Allocator.Error;

arena: std.mem.Allocator,
scopes: std.ArrayList(Scope) = .empty,
diagnostics: std.ArrayList(Diagnostic) = .empty,

pub fn check(gpa: std.mem.Allocator, program: Ast.Program) !Checked {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var checker: Checker = .{ .arena = arena };

    // The prelude sits in the outermost scope, matching the resolver.
    try checker.scopes.append(arena, .empty);
    for (Resolver.prelude) |name| {
        try checker.scopes.items[0].put(arena, name, .{ .type = .invalid, .assigned = true });
    }

    try checker.scopes.append(arena, .empty);
    try checker.checkStatements(program.statements);

    const owned = try checker.diagnostics.toOwnedSlice(arena);
    return .{ .arena_state = arena_state, .diagnostics = owned };
}

fn find(self: *Checker, name: []const u8) ?*Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].getPtr(name)) |binding| return binding;
    }
    return null;
}

fn report(
    self: *Checker,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = help,
    });
}

// Statements.

fn checkStatements(self: *Checker, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| try self.checkStatement(statement);
}

fn checkBlock(self: *Checker, block: Ast.Block) Error!void {
    try self.scopes.append(self.arena, .empty);
    defer _ = self.scopes.pop();
    try self.checkStatements(block.statements);
}

fn checkStatement(self: *Checker, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| _ = try self.typeOf(expression),
        .declaration => |declaration| try self.checkDeclaration(declaration),
        .assignment => |assignment| try self.checkAssignment(assignment),
        .conditional => |conditional| try self.checkConditional(conditional),
    }
}

fn checkDeclaration(self: *Checker, declaration: Ast.Declaration) Error!void {
    var declared: Type = .invalid;
    var assigned = true;

    if (declaration.annotation) |annotation| {
        declared = try self.resolveTypeExpression(annotation);
    }

    if (declaration.initializer) |initializer| {
        const actual = try self.typeOf(initializer);
        if (declaration.annotation != null) {
            if (!actual.assignableTo(declared)) {
                try self.report(
                    initializer.span,
                    "this is {s}, but `{s}` was declared as {s}",
                    .{ actual.name(), declaration.name, declared.name() },
                    "Give the declaration the type of its value, or convert the value to match.",
                );
            }
        } else {
            // Section 4.1 infers the local's type from its initializer.
            declared = actual;
        }
    } else {
        // No initializer, so the annotation is the only source of a type and
        // the binding starts out unassigned.
        assigned = false;
        if (declaration.annotation == null) {
            try self.report(
                declaration.name_span,
                "`{s}` needs a type or a value",
                .{declaration.name},
                "Write `var name = value` to infer the type, or `var name: Type` to declare it without one.",
            );
        }
    }

    const current = &self.scopes.items[self.scopes.items.len - 1];
    try current.put(self.arena, declaration.name, .{ .type = declared, .assigned = assigned });
}

fn checkAssignment(self: *Checker, assignment: Ast.Assignment) Error!void {
    const value = try self.typeOf(assignment.value);
    const binding = self.find(assignment.name) orelse return; // the resolver reported it

    if (assignment.operation) |operation| {
        // Section 5.3 lowers a compound assignment through the same operation,
        // so its result type is the operation's, not the right-hand side's.
        if (!binding.assigned) try self.reportUnassigned(assignment.name_span, assignment.name);
        const result = try self.arithmetic(assignment.name_span, operation, binding.type, value);

        if (!result.assignableTo(binding.type)) {
            // Worth explaining rather than only reporting. `/` always produces a
            // Float, so `count /= 2` on an Int can never store its result, and
            // the reason is two sections away from the line that failed.
            try self.report(
                assignment.name_span,
                "`{s}` produces {s}, which `{s}` cannot hold because it is {s}",
                .{ operation.lexeme(), result.name(), assignment.name, binding.type.name() },
                if (operation == .divide)
                    "`/` always produces a Float. Use `//=` to keep whole numbers, or declare the name as a Float."
                else
                    "Declare the name with a type that can hold the result.",
            );
        }

        binding.assigned = true;
        return;
    }

    if (!value.assignableTo(binding.type)) {
        try self.report(
            assignment.value.span,
            "this is {s}, but `{s}` holds {s}",
            .{ value.name(), assignment.name, binding.type.name() },
            "Assign a value of the declared type, or convert it first.",
        );
    }

    binding.assigned = true;
}

/// Section 4.1 proves definite assignment through control flow. A name counts as
/// assigned after an `if` only when every path assigns it, which means both a
/// `then` and an `else` that each assign it. Without an `else` there is a path
/// that skips the block entirely, so nothing is proved.
fn checkConditional(self: *Checker, conditional: Ast.If) Error!void {
    try self.requireCondition(conditional.condition);

    const before = try self.snapshot();
    try self.checkBlock(conditional.then_block);
    const after_then = try self.snapshot();

    const otherwise = conditional.otherwise orelse {
        // No else: restore, because the block may not have run at all.
        self.restore(before);
        return;
    };

    self.restore(before);
    switch (otherwise) {
        .block => |block| try self.checkBlock(block),
        .chained => |chained| try self.checkStatement(chained.*),
    }

    // Assigned on both paths, so assigned afterwards.
    self.intersect(after_then);
}

/// The assignment state of every binding currently in scope, innermost last.
const Snapshot = [][]bool;

fn snapshot(self: *Checker) Error!Snapshot {
    const result = try self.arena.alloc([]bool, self.scopes.items.len);
    for (self.scopes.items, result) |scope, *flags| {
        flags.* = try self.arena.alloc(bool, scope.count());
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) flags.*[index] = binding.assigned;
    }
    return result;
}

fn restore(self: *Checker, state: Snapshot) void {
    for (self.scopes.items, state) |*scope, flags| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) binding.assigned = flags[index];
    }
}

fn intersect(self: *Checker, other: Snapshot) void {
    for (self.scopes.items, other) |*scope, flags| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            binding.assigned = binding.assigned and flags[index];
        }
    }
}

fn requireCondition(self: *Checker, expression: *const Ast.Expression) Error!void {
    const actual = try self.typeOf(expression);
    if (actual.kind == .invalid or actual.kind == .bool) return;
    try self.report(
        expression.span,
        "a condition must be a Bool, but this is {s}",
        .{actual.name()},
        "Compare it to something, as in `count > 0`. Emerald has no truthy or falsey values.",
    );
}

/// The canonical diagnostic of section 17.1, reproduced exactly, including the
/// name in its correction.
fn reportUnassigned(self: *Checker, span: Source.Span, name: []const u8) Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, "`{s}` may not have been assigned", .{name}),
        .span = span,
        .help = try std.fmt.allocPrint(
            self.arena,
            "Assign `{s}` on every branch before reading it.",
            .{name},
        ),
    });
}

fn resolveTypeExpression(self: *Checker, annotation: Ast.TypeExpression) Error!Type {
    if (annotation.question_span) |question| {
        try self.report(
            question,
            "optional types are not available yet",
            .{},
            "Declare the type without `?` for now.",
        );
        return .invalid;
    }

    return Type.fromName(annotation.name) orelse {
        try self.report(
            annotation.span,
            "`{s}` is not a type",
            .{annotation.name},
            "The types available so far are `Int`, `Float`, `Bool`, and `Nothing`.",
        );
        return .invalid;
    };
}

// Expressions.

fn typeOf(self: *Checker, expression: *const Ast.Expression) Error!Type {
    return switch (expression.data) {
        .int_literal => .int,
        .float_literal => .float,
        .bool_literal => .bool,
        .nothing_literal => .nothing,

        .name => |name| blk: {
            const binding = self.find(name) orelse break :blk .invalid;
            if (!binding.assigned) {
                try self.reportUnassigned(expression.span, name);
                // Treated as assigned from here so one unassigned read does not
                // report again at every later use.
                binding.assigned = true;
            }
            break :blk binding.type;
        },

        .unary => |unary| self.typeOfUnary(expression, unary),
        .binary => |binary| self.typeOfBinary(expression, binary),
        .logical => |logical| self.typeOfLogical(logical),
        .comparison => |comparison| self.typeOfComparison(comparison),
        .call => |call| self.typeOfCall(call),
    };
}

fn typeOfUnary(
    self: *Checker,
    expression: *const Ast.Expression,
    unary: Ast.Expression.Unary,
) Error!Type {
    const operand = try self.typeOf(unary.operand);
    if (operand.kind == .invalid) return .invalid;

    switch (unary.operator) {
        .negate => {
            if (operand.isNumber()) return operand;
            try self.report(
                expression.span,
                "`-` needs a number, but this is {s}",
                .{operand.name()},
                "Use `not` to invert a Bool.",
            );
        },
        .not => {
            if (operand.kind == .bool) return .bool;
            try self.report(
                expression.span,
                "`not` needs a Bool, but this is {s}",
                .{operand.name()},
                "Compare it to something first, as in `not (count > 0)`.",
            );
        },
    }
    return .invalid;
}

fn typeOfBinary(
    self: *Checker,
    expression: *const Ast.Expression,
    binary: Ast.Expression.Binary,
) Error!Type {
    const left = try self.typeOf(binary.left);
    const right = try self.typeOf(binary.right);
    return self.arithmetic(expression.span, binary.operator, left, right);
}

fn arithmetic(
    self: *Checker,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: Type,
    right: Type,
) Error!Type {
    // Section 5.3: `/` and `**` always produce a Float.
    const always_float = operator == .divide or operator == .power;
    return Type.arithmeticResult(left, right, always_float) orelse {
        try self.report(
            span,
            "{s} needs numbers, but this is {s} and {s}",
            .{ operator.describe(), left.name(), right.name() },
            "Arithmetic works on Int and Float.",
        );
        return .invalid;
    };
}

fn typeOfLogical(self: *Checker, logical: Ast.Expression.Logical) Error!Type {
    try self.requireCondition(logical.left);
    try self.requireCondition(logical.right);
    return .bool;
}

/// A comparison chain yields a `Bool`, and every adjacent pair has to be
/// comparable. Section 4.4 allows a mixed `Int`/`Float` comparison, which is why
/// this asks whether the pair is numeric rather than whether the types match.
fn typeOfComparison(self: *Checker, comparison: Ast.Expression.Comparison) Error!Type {
    var left = try self.typeOf(comparison.operands[0]);

    for (comparison.operators, comparison.operands[1..]) |_, operand_node| {
        const right = try self.typeOf(operand_node);
        const comparable = left.kind == .invalid or right.kind == .invalid or
            (left.isNumber() and right.isNumber()) or left.kind == right.kind;

        if (!comparable) {
            try self.report(
                operand_node.span,
                "{s} and {s} cannot be compared",
                .{ left.name(), right.name() },
                "Comparison needs two values of the same kind.",
            );
        }
        left = right;
    }

    return .bool;
}

fn typeOfCall(self: *Checker, call: Ast.Expression.Call) Error!Type {
    for (call.arguments) |argument| _ = try self.typeOf(argument);
    // `print` is the only callable, and section 15.2 gives it no result.
    return .nothing;
}
