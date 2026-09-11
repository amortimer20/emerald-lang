//! Name resolution.
//!
//! Section 19.2 puts this between parsing and evaluation, and these problems
//! belong here rather than in the interpreter because they are properties of the
//! text rather than of a particular run. A name declared inside `if false { }`
//! still shadows, and a program that never reaches a bad assignment is still
//! wrong.
//!
//! Section 6.1 supplies the scope rules. Every block is a scope, a local does not
//! leak out of the block that declared it, sibling scopes may reuse a name, and
//! shadowing a visible local within the same function is an error because the
//! writer usually meant assignment. Crossing a function boundary is allowed: a
//! parameter or local may reuse a module-level name.
//!
//! Section 7.1 supplies the visibility rules that functions add. Function
//! declarations are hoisted, so every top-level function is visible from the
//! start of the file. Variables are visible only from their declarations, and a
//! function body is walked where it is written, so it sees exactly the module
//! variables declared above it.
//!
//! Hoisting means a function can be called before a variable it reads has been
//! assigned. Section 7.1 forbids that ("hoisting never permits reading an
//! uninitialized captured variable"), and the checker enforces it at each call
//! site. It needs to know which module variables each function reads and which
//! functions each one calls, which is only knowable with scopes in hand, so this
//! pass records both as `Facts`.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Source = @import("Source.zig");

const Resolver = @This();

/// A set of names, used for both halves of `Facts`.
pub const NameSet = std.StringHashMapUnmanaged(void);

/// What name resolution learned about functions, for the checker.
pub const Facts = struct {
    /// For each function, the module-level variables its own body reads. A
    /// compound assignment reads before it writes, so it counts; a plain
    /// assignment does not, because it needs no earlier value.
    module_reads: std.StringHashMapUnmanaged(NameSet) = .empty,
    /// For each function, the other program functions its own body calls.
    /// Calls to prelude functions are not recorded; they read no program state.
    calls: std.StringHashMapUnmanaged(NameSet) = .empty,
};

pub const Resolved = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    facts: Facts,

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

pub const BindingKind = enum { variable, parameter, function };

const Binding = struct {
    mutable: bool,
    /// Where the name was declared, so a later diagnostic can point at it.
    span: Source.Span,
    /// Decides the reason a reassignment diagnostic gives: section 4.3 makes a
    /// `const` read-only, section 7.1 makes a parameter read-only, and a
    /// function is not a variable at all.
    kind: BindingKind = .variable,
};

const Scope = std.StringHashMapUnmanaged(Binding);

/// Stated rather than inferred: the walk functions are mutually recursive, and
/// an inferred set would be a dependency loop.
const Error = std.mem.Allocator.Error;

/// The prelude is scope 0 and the module scope is scope 1.
const prelude_scope = 0;
const module_scope = 1;

arena: std.mem.Allocator,
scopes: std.ArrayList(Scope) = .empty,
diagnostics: std.ArrayList(Diagnostic) = .empty,
facts: Facts = .{},
/// The lowest scope index that counts as "the same function" for section 6.1's
/// shadowing rule. At the top level that is the module scope; inside a
/// function body it is the function's own parameter scope, which is what lets
/// a parameter or local reuse a module-level name.
function_boundary: usize = module_scope,
/// The function whose body is being walked, or null at the top level.
current_function: ?[]const u8 = null,
/// Every top-level variable and where it is declared, so a name used above its
/// declaration can be reported as exactly that rather than as a misspelling.
module_declarations: std.StringHashMapUnmanaged(Source.Span) = .empty,

pub fn resolve(gpa: std.mem.Allocator, program: Ast.Program) !Resolved {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolver: Resolver = .{ .arena = arena };

    // The prelude sits outside the program's own scopes, so a program may
    // declare a name that matches one without it counting as shadowing a local.
    try resolver.push();
    for (prelude) |name| {
        try resolver.scopes.items[prelude_scope].put(arena, name, .{
            .mutable = false,
            .span = .{ .start = 0, .end = 0 },
            .kind = .function,
        });
    }

    try resolver.push();
    try resolver.hoistFunctions(program.statements);
    for (program.statements) |statement| {
        if (statement.data == .declaration) {
            const declaration = statement.data.declaration;
            try resolver.module_declarations.put(arena, declaration.name, declaration.name_span);
        }
    }
    try resolver.walkStatements(program.statements);

    const owned = try resolver.diagnostics.toOwnedSlice(arena);
    return .{ .arena_state = arena_state, .diagnostics = owned, .facts = resolver.facts };
}

/// Section 7.1: function declarations are hoisted within their scope. Every
/// top-level function enters the module scope before any statement is walked,
/// so a function may be called above its declaration, and may call itself.
///
/// Functions and variables share one namespace, as section 7.3's "a name
/// declares one function" implies, so a variable that reuses a function's name
/// is the ordinary "already declared" error however the two are ordered in the
/// file.
fn hoistFunctions(self: *Resolver, statements: []const Ast.Statement) Error!void {
    const module = &self.scopes.items[module_scope];
    for (statements) |statement| {
        const function = switch (statement.data) {
            .function_declaration => |f| f,
            else => continue,
        };
        if (module.contains(function.name)) {
            try self.report(
                function.name_span,
                "`{s}` is already declared",
                .{function.name},
                "A name declares one function. Choose a different name, or remove the duplicate.",
            );
            continue;
        }
        try module.put(self.arena, function.name, .{
            .mutable = false,
            .span = function.name_span,
            .kind = .function,
        });
        try self.facts.module_reads.put(self.arena, function.name, .empty);
        try self.facts.calls.put(self.arena, function.name, .empty);
    }
}

fn push(self: *Resolver) !void {
    try self.scopes.append(self.arena, .empty);
}

fn pop(self: *Resolver) void {
    _ = self.scopes.pop();
}

const Found = struct { binding: Binding, scope: usize };

fn lookup(self: *Resolver, name: []const u8) ?Found {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].get(name)) |binding| {
            return .{ .binding = binding, .scope = index };
        }
    }
    return null;
}

/// Whether the name is already visible within the current function, which is
/// what section 6.1 forbids redeclaring. Names beyond `function_boundary` — the
/// module scope seen from inside a function, and the prelude everywhere — may
/// be reused.
fn visibleLocal(self: *Resolver, name: []const u8) ?Binding {
    var index = self.scopes.items.len;
    while (index > self.function_boundary) {
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

/// A name that resolves to nothing. When a top-level variable of that name is
/// declared further down, the reader has most likely run into section 7.1's
/// "variables are visible only from their declarations", so that is what the
/// diagnostic says.
fn reportUndefined(self: *Resolver, span: Source.Span, name: []const u8, help: []const u8) Error!void {
    if (self.module_declarations.get(name)) |declared| {
        if (declared.start > span.start) {
            return self.report(
                span,
                "`{s}` is not declared until later in the file",
                .{name},
                "A variable can only be used below its declaration. Move the declaration above this line.",
            );
        }
    }
    try self.report(span, "`{s}` is not defined", .{name}, help);
}

/// Records that the current function reads `name`, if `name` resolved to a
/// module-level variable. Reads of the function's own parameters and locals,
/// and anything at the top level, are not captures.
fn noteRead(self: *Resolver, found: Found, name: []const u8) Error!void {
    const function = self.current_function orelse return;
    if (found.scope != module_scope or found.binding.kind != .variable) return;
    try self.facts.module_reads.getPtr(function).?.put(self.arena, name, {});
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

            // Section 4.1 lets a variable start unassigned, but a `const` can
            // never be assigned afterward, so it would stay that way. Later
            // assignments are then let through, since they are how this
            // `const` was meant to get its value, and the one report covers it.
            const missing_value = !declaration.mutable and declaration.initializer == null;
            if (missing_value) {
                try self.report(
                    declaration.name_span,
                    "`{s}` is a `const`, so it needs a value where it is declared",
                    .{declaration.name},
                    "Write its value after `=`, or declare it with `var` if it is assigned later.",
                );
            }

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
                .mutable = declaration.mutable or missing_value,
                .span = declaration.name_span,
            });
        },

        .assignment => |assignment| {
            try self.walkExpression(assignment.value);

            const found = self.lookup(assignment.name) orelse {
                return self.reportUndefined(
                    assignment.name_span,
                    assignment.name,
                    "Declare it first with `var`, or check the spelling.",
                );
            };

            // A compound assignment reads the current value first, so it needs
            // the variable to be assigned already; a plain one does not.
            if (assignment.operation != null) try self.noteRead(found, assignment.name);

            if (!found.binding.mutable) switch (found.binding.kind) {
                .variable => try self.report(
                    assignment.name_span,
                    "`{s}` cannot be reassigned",
                    .{assignment.name},
                    "It was declared with `const`. Use `var` if the value needs to change.",
                ),
                .parameter => try self.report(
                    assignment.name_span,
                    "`{s}` cannot be reassigned",
                    .{assignment.name},
                    "Parameters are read-only. Assign it to a local variable first if you need a version that can change.",
                ),
                .function => try self.report(
                    assignment.name_span,
                    "`{s}` is a function and cannot be assigned to",
                    .{assignment.name},
                    "Declare a variable with a different name to hold the value.",
                ),
            };
        },

        .conditional => |conditional| {
            try self.walkExpression(conditional.condition);
            try self.walkBlock(conditional.then_block);
            if (conditional.otherwise) |otherwise| switch (otherwise) {
                .block => |block| try self.walkBlock(block),
                .chained => |chained| try self.walkStatement(chained.*),
            };
        },

        .function_declaration => |function| try self.walkFunctionBody(function),

        .return_statement => |return_statement| {
            if (return_statement.value) |value| try self.walkExpression(value);
        },
    }
}

/// Walks a function body where it is written. The module scope stays visible
/// underneath, holding exactly the variables declared above this function plus
/// every function (all hoisted), which is section 7.1's visibility.
///
/// The parser only accepts a function declaration at the top level, so the
/// scope stack here is always the prelude and the module scope and nothing else;
/// no enclosing block's locals can leak in.
fn walkFunctionBody(self: *Resolver, function: Ast.FunctionDeclaration) Error!void {
    std.debug.assert(self.scopes.items.len == module_scope + 1);

    try self.push();
    const outer_boundary = self.function_boundary;
    const outer_function = self.current_function;
    self.function_boundary = self.scopes.items.len - 1;
    self.current_function = function.name;
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.current_function = outer_function;
    }

    const parameters = &self.scopes.items[self.scopes.items.len - 1];
    for (function.parameters) |parameter| {
        if (parameters.contains(parameter.name)) {
            try self.report(
                parameter.name_span,
                "`{s}` is already a parameter",
                .{parameter.name},
                "Give each parameter a different name.",
            );
            continue;
        }
        try parameters.put(self.arena, parameter.name, .{
            .mutable = false, // Section 7.1: parameters are read-only.
            .span = parameter.name_span,
            .kind = .parameter,
        });
    }

    // The body's top level shares the parameters' scope, so a local that
    // reuses a parameter's name is shadowing within the same function.
    try self.walkStatements(function.body.statements);
}

fn walkExpression(self: *Resolver, expression: *const Ast.Expression) Error!void {
    switch (expression.data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal => {},

        .name => |name| {
            const found = self.lookup(name) orelse {
                return self.reportUndefined(
                    expression.span,
                    name,
                    "Check the spelling, or declare it before this line.",
                );
            };
            try self.noteRead(found, name);
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
            if (self.current_function) |caller| {
                if (call.callee.data == .name) {
                    const callee = call.callee.data.name;
                    if (self.lookup(callee)) |found| {
                        if (found.scope == module_scope and found.binding.kind == .function) {
                            try self.facts.calls.getPtr(caller).?.put(self.arena, callee, {});
                        }
                    }
                }
            }
            for (call.arguments) |argument| try self.walkExpression(argument);
        },
    }
}
