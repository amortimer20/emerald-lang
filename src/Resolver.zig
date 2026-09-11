//! Name resolution.
//!
//! Section 19.2 puts this between parsing and evaluation, and these problems
//! belong here rather than in the interpreter because they are properties of the
//! text rather than of a particular run. A name declared inside `if false { }`
//! still shadows, and a program that never reaches a bad assignment is still
//! wrong.
//!
//! Section 6.1 supplies the rules. Every block is a scope, a local does not leak
//! out of the block that declared it, sibling scopes may reuse a name, and
//! shadowing a visible local within the same function is an error because the
//! writer usually meant assignment.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Source = @import("Source.zig");

const Resolver = @This();

pub const Resolved = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn ok(self: Resolved) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Resolved) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

/// Section 15.2's prelude. These are callable without qualification and are not
/// declared by any program, so they live in a scope of their own.
pub const prelude = [_][]const u8{"print"};

const Binding = struct {
    mutable: bool,
    /// Where the name was declared, so a later diagnostic can point at it.
    span: Source.Span,
};

const Scope = std.StringHashMapUnmanaged(Binding);

/// Stated rather than inferred: the walk functions are mutually recursive, and
/// an inferred set would be a dependency loop.
const Error = std.mem.Allocator.Error;

arena: std.mem.Allocator,
scopes: std.ArrayList(Scope) = .empty,
diagnostics: std.ArrayList(Diagnostic) = .empty,

pub fn resolve(gpa: std.mem.Allocator, program: Ast.Program) !Resolved {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolver: Resolver = .{ .arena = arena };

    // The prelude sits outside the program's own scopes, so a program may
    // declare a name that matches one without it counting as shadowing a local.
    try resolver.push();
    for (prelude) |name| {
        try resolver.scopes.items[0].put(arena, name, .{
            .mutable = false,
            .span = .{ .start = 0, .end = 0 },
        });
    }

    try resolver.push();
    try resolver.walkStatements(program.statements);

    const owned = try resolver.diagnostics.toOwnedSlice(arena);
    return .{ .arena_state = arena_state, .diagnostics = owned };
}

fn push(self: *Resolver) !void {
    try self.scopes.append(self.arena, .empty);
}

fn pop(self: *Resolver) void {
    _ = self.scopes.pop();
}

/// The scope index where the program's own names begin. Everything below it is
/// the prelude.
const first_program_scope = 1;

fn lookup(self: *Resolver, name: []const u8) ?Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].get(name)) |binding| return binding;
    }
    return null;
}

/// Whether the name is already visible as a local, which is what section 6.1
/// forbids redeclaring. A prelude name is not a local, so shadowing `print` is
/// allowed the same way a local may reuse a module-level name.
fn visibleLocal(self: *Resolver, name: []const u8) ?Binding {
    var index = self.scopes.items.len;
    while (index > first_program_scope) {
        index -= 1;
        if (self.scopes.items[index].get(name)) |binding| return binding;
    }
    return null;
}

fn report(
    self: *Resolver,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) !void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = help,
    });
}

fn walkStatements(self: *Resolver, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| try self.walkStatement(statement);
}

fn walkBlock(self: *Resolver, block: Ast.Block) Error!void {
    try self.push();
    defer self.pop();
    try self.walkStatements(block.statements);
}

fn walkStatement(self: *Resolver, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| try self.walkExpression(expression),

        .declaration => |declaration| {
            // The initializer is resolved first, so `var x = x` reports the
            // right-hand `x` as undefined rather than quietly seeing itself.
            if (declaration.initializer) |initializer| try self.walkExpression(initializer);

            if (self.visibleLocal(declaration.name) != null) {
                try self.report(
                    declaration.name_span,
                    "`{s}` is already declared",
                    .{declaration.name},
                    "Assign to the existing name instead of declaring it again, or choose a different name.",
                );
                return;
            }

            const current = &self.scopes.items[self.scopes.items.len - 1];
            try current.put(self.arena, declaration.name, .{
                .mutable = declaration.mutable,
                .span = declaration.name_span,
            });
        },

        .assignment => |assignment| {
            try self.walkExpression(assignment.value);

            const binding = self.lookup(assignment.name) orelse {
                try self.report(
                    assignment.name_span,
                    "`{s}` is not defined",
                    .{assignment.name},
                    "Declare it first with `var`, or check the spelling.",
                );
                return;
            };

            if (!binding.mutable) {
                try self.report(
                    assignment.name_span,
                    "`{s}` cannot be reassigned",
                    .{assignment.name},
                    "It was declared with `const`. Use `var` if the value needs to change.",
                );
            }
        },

        .conditional => |conditional| {
            try self.walkExpression(conditional.condition);
            try self.walkBlock(conditional.then_block);
            if (conditional.otherwise) |otherwise| switch (otherwise) {
                .block => |block| try self.walkBlock(block),
                .chained => |chained| try self.walkStatement(chained.*),
            };
        },
    }
}

fn walkExpression(self: *Resolver, expression: *const Ast.Expression) Error!void {
    switch (expression.data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal => {},

        .name => |name| if (self.lookup(name) == null) {
            try self.report(
                expression.span,
                "`{s}` is not defined",
                .{name},
                "Check the spelling, or declare it before this line.",
            );
        },

        .unary => |unary| try self.walkExpression(unary.operand),
        .binary => |binary| {
            try self.walkExpression(binary.left);
            try self.walkExpression(binary.right);
        },
        .logical => |logical| {
            try self.walkExpression(logical.left);
            try self.walkExpression(logical.right);
        },
        .comparison => |comparison| {
            for (comparison.operands) |operand| try self.walkExpression(operand);
        },
        .call => |call| {
            try self.walkExpression(call.callee);
            for (call.arguments) |argument| try self.walkExpression(argument);
        },
    }
}
