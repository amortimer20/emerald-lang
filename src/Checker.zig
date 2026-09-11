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
//!
//! # Functions
//!
//! The top level is checked in the order it is written, since that order is
//! what definite assignment follows. Function bodies are checked afterwards,
//! each against a view of the module scope in which every variable counts as
//! assigned. A function may run at any point after the top level begins —
//! declarations are hoisted — so nothing about the state at the point where it
//! happens to be written can apply inside it.
//!
//! What the view gives up, the call sites take back. Section 7.1 says hoisting
//! "never permits reading an uninitialized captured variable", so each call made
//! from top-level code checks that every module variable the callee reads,
//! directly or through the functions it calls, is already assigned there.
//!
//! A call can need a function's return type before that function's body has been
//! checked. With an annotation, or with no value-returning `return` at all, the
//! type is known without looking inside. Otherwise it is inferred on the spot,
//! which section 7.2 permits only for a function that is not recursive.

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
    /// Every function's checked signature, for the interpreter.
    signatures: Type.Signatures,

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
    /// A function's name. Its `type` is unused; a call goes through
    /// `signatureFor` instead.
    is_function: bool = false,
};

const Scope = std.StringHashMapUnmanaged(Binding);

const Signature = Type.Signature;

/// Stated rather than inferred: the walk functions are mutually recursive.
const Error = std.mem.Allocator.Error;

arena: std.mem.Allocator,
/// The scopes in force, innermost last. Pointers rather than values, so the
/// prelude and module scopes keep a stable address while a function body is
/// checked against a different list.
scopes: std.ArrayList(*Scope) = .empty,
prelude: *Scope,
module: *Scope,
diagnostics: std.ArrayList(Diagnostic) = .empty,

facts: Resolver.Facts,
declarations: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
/// Memoized by `signatureFor`.
signatures: Type.Signatures = .empty,
/// Bodies already checked, so each is checked exactly once whichever of
/// inference or the deferred pass reaches it first.
bodies_checked: Resolver.NameSet = .empty,
/// Memoized by `capturesOf`.
captures: std.StringHashMapUnmanaged(Resolver.NameSet) = .empty,
/// The enclosing function's return type while checking its body. Null means a
/// return type is still being inferred, and `return expr` records its value's
/// type in `pending_return_types` instead of checking it.
current_return_type: ?Type = null,
/// Whether `return` is legal here. Section 14.1's top-level `return`, which
/// ends the program, is deferred, so it is rejected outside a function.
in_function: bool = false,
pending_return_types: std.ArrayList(Type) = .empty,

pub fn check(gpa: std.mem.Allocator, program: Ast.Program, facts: Resolver.Facts) !Checked {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const prelude = try arena.create(Scope);
    prelude.* = .empty;
    for (Resolver.prelude) |name| {
        try prelude.put(arena, name, .{ .type = .invalid, .assigned = true, .is_function = true });
    }
    const module = try arena.create(Scope);
    module.* = .empty;

    var checker: Checker = .{ .arena = arena, .prelude = prelude, .module = module, .facts = facts };
    try checker.scopes.append(arena, prelude);
    try checker.scopes.append(arena, module);

    // Hoisted, as in the resolver. The resolver has rejected duplicate names,
    // so every declaration here is the only one with its name.
    for (program.statements) |statement| {
        const function = switch (statement.data) {
            .function_declaration => |f| f,
            else => continue,
        };
        try checker.declarations.put(arena, function.name, function);
        try module.put(arena, function.name, .{ .type = .invalid, .assigned = true, .is_function = true });
    }

    try checker.checkStatements(program.statements);

    // Every body, in the order written. Most were not needed during the walk
    // above; those that were have already been checked and are skipped.
    for (program.statements) |statement| {
        if (statement.data == .function_declaration) {
            try checker.ensureBodyChecked(statement.data.function_declaration.name);
        }
    }

    // Bodies are checked after the top level and inference can check one early,
    // so diagnostics are collected out of order. The reader wants them in the
    // order of the file.
    const owned = try checker.diagnostics.toOwnedSlice(arena);
    std.mem.sort(Diagnostic, owned, {}, earlierInSource);
    return .{ .arena_state = arena_state, .diagnostics = owned, .signatures = checker.signatures };
}

fn earlierInSource(_: void, a: Diagnostic, b: Diagnostic) bool {
    return a.span.start < b.span.start;
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

/// Like `report`, but for a correction that names something from the program.
fn reportWithHelp(
    self: *Checker,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    comptime help_format: []const u8,
    help_args: anytype,
) Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = try std.fmt.allocPrint(self.arena, help_format, help_args),
    });
}

fn pushScope(self: *Checker) Error!void {
    const scope = try self.arena.create(Scope);
    scope.* = .empty;
    try self.scopes.append(self.arena, scope);
}

// Statements.

fn checkStatements(self: *Checker, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| try self.checkStatement(statement);
}

fn checkBlock(self: *Checker, block: Ast.Block) Error!void {
    try self.pushScope();
    defer _ = self.scopes.pop();
    try self.checkStatements(block.statements);
}

fn checkStatement(self: *Checker, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| _ = try self.typeOf(expression),
        .declaration => |declaration| try self.checkDeclaration(declaration),
        .assignment => |assignment| try self.checkAssignment(assignment),
        .conditional => |conditional| try self.checkConditional(conditional),
        // Checked after the top level; see the module comment.
        .function_declaration => {},
        .return_statement => |return_statement| try self.checkReturn(return_statement),
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

    const current = self.scopes.items[self.scopes.items.len - 1];
    try current.put(self.arena, declaration.name, .{ .type = declared, .assigned = assigned });
}

fn checkAssignment(self: *Checker, assignment: Ast.Assignment) Error!void {
    const value = try self.typeOf(assignment.value);
    const binding = self.find(assignment.name) orelse return; // the resolver reported it
    if (binding.is_function) return; // so did this

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
///
/// A branch that always returns is left out of the merge rather than
/// intersected into it. Otherwise a guard clause like
///
///     var x: Int
///     if cond { x = 1 } else { return }
///     print(x)
///
/// would be rejected, even though the only way to reach `print(x)` is through
/// the branch that assigns it.
fn checkConditional(self: *Checker, conditional: Ast.If) Error!void {
    try self.requireCondition(conditional.condition);

    const before = try self.snapshot();
    try self.checkBlock(conditional.then_block);
    const after_then = try self.snapshot();
    const then_returns = blockAlwaysReturns(conditional.then_block.statements);

    const otherwise = conditional.otherwise orelse {
        // No else: the block may not have run at all. This holds even when the
        // block always returns, since reaching past it means it did not run.
        self.restore(before);
        return;
    };

    self.restore(before);
    const otherwise_returns = switch (otherwise) {
        .block => |block| blk: {
            try self.checkBlock(block);
            break :blk blockAlwaysReturns(block.statements);
        },
        .chained => |chained| blk: {
            try self.checkStatement(chained.*);
            break :blk stmtAlwaysReturns(chained.*);
        },
    };

    if (then_returns and otherwise_returns) {
        // Nothing after the `if` is reachable. Section 14.1's warning for
        // unreachable code is deferred (diagnostics have no severity yet), so
        // rather than report "may not have been assigned" in code that can
        // never run, every binding counts as assigned from here.
        self.markAllAssigned();
    } else if (then_returns) {
        // Only the else branch continues, and checking it left its state in
        // place.
    } else if (otherwise_returns) {
        self.restore(after_then);
    } else {
        self.intersect(after_then);
    }
}

fn checkReturn(self: *Checker, return_statement: Ast.Return) Error!void {
    if (!self.in_function) {
        try self.report(
            return_statement.keyword_span,
            "`return` can only be used inside a function",
            .{},
            "Remove it, or move this code into a function.",
        );
        return;
    }

    const value = return_statement.value orelse {
        if (self.current_return_type) |expected| {
            if (expected.kind != .nothing and expected.kind != .invalid) {
                try self.report(
                    return_statement.keyword_span,
                    "this function must return a value",
                    .{},
                    "Add a value, as in `return 0`.",
                );
            }
        } else {
            // While inferring, a bare return contributes Nothing, so a body
            // that returns a value on one path and nothing on another is
            // reported as ambiguous by `inferredReturnType`.
            try self.pending_return_types.append(self.arena, .nothing);
        }
        return;
    };

    const actual = try self.typeOf(value);
    const expected = self.current_return_type orelse {
        try self.pending_return_types.append(self.arena, actual);
        return;
    };

    if (expected.kind == .nothing) {
        // Only reachable through an explicit `: Nothing`. Without an
        // annotation, a body with `return expr` has its type inferred from
        // that value, per section 7.2's distinction between "no result" and an
        // explicit `Nothing`.
        try self.report(
            value.span,
            "this function returns Nothing, so `return` cannot produce a value",
            .{},
            "Remove the value, or declare the function with the type of what it returns.",
        );
    } else if (expected.kind != .invalid and !actual.assignableTo(expected)) {
        try self.report(
            value.span,
            "this is {s}, but the function returns {s}",
            .{ actual.name(), expected.name() },
            "Return a value of the declared type, or convert it first.",
        );
    }
}

// Functions.

/// A function's signature, computed once on first need.
///
/// Section 7.2 requires an explicit return type on a recursive or mutually
/// recursive function "so checking does not depend on circular inference".
/// Inference only happens after that is ruled out, which is what keeps this
/// from chasing its own tail. A provisional signature is stored while inferring
/// all the same, so a re-entrant call could never recurse forever.
fn signatureFor(self: *Checker, name: []const u8) Error!Signature {
    if (self.signatures.get(name)) |signature| return signature;

    const declaration = self.declarations.get(name).?;
    const parameter_types = try self.arena.alloc(Type, declaration.parameters.len);
    const parameter_names = try self.arena.alloc([]const u8, declaration.parameters.len);
    for (declaration.parameters, 0..) |parameter, index| {
        parameter_types[index] = try self.resolveTypeExpression(parameter.annotation);
        parameter_names[index] = parameter.name;
    }

    var signature: Signature = .{
        .parameters = parameter_types,
        .parameter_names = parameter_names,
        .return_type = .invalid,
    };

    if (declaration.return_annotation) |annotation| {
        signature.return_type = try self.resolveTypeExpression(annotation);
    } else if (!blockHasValueReturn(declaration.body.statements)) {
        // Nothing to infer: section 7.2's "a function returning no value may
        // omit its return type".
        signature.return_type = .nothing;
    } else if (try self.isRecursive(name)) {
        try self.report(
            declaration.name_span,
            "`{s}` is recursive and needs an explicit return type",
            .{name},
            "Add a return type, so checking does not depend on inferring it from a call to itself.",
        );
    } else {
        try self.signatures.put(self.arena, name, signature); // provisional
        const saved_pending = self.pending_return_types;
        self.pending_return_types = .empty;

        try self.checkFunctionBody(declaration, parameter_types, null);
        try self.bodies_checked.put(self.arena, name, {});

        signature.return_type = try self.inferredReturnType(
            self.pending_return_types.items,
            name,
            declaration.name_span,
        );
        self.pending_return_types = saved_pending;
        try self.checkAllPathsReturn(declaration, signature.return_type);
    }

    try self.signatures.put(self.arena, name, signature);
    return signature;
}

fn ensureBodyChecked(self: *Checker, name: []const u8) Error!void {
    const signature = try self.signatureFor(name);
    if (self.bodies_checked.contains(name)) return;
    try self.bodies_checked.put(self.arena, name, {});

    const declaration = self.declarations.get(name).?;
    try self.checkFunctionBody(declaration, signature.parameters, signature.return_type);
    try self.checkAllPathsReturn(declaration, signature.return_type);
}

/// Checks a function body against its parameters and a view of the module and
/// prelude in which everything counts as assigned (see the module comment).
///
/// The view is a fresh copy, so nothing done inside the body — assignments,
/// merging branches — can disturb the definite-assignment state of the top level
/// that is paused while an early inference runs.
///
/// `expected_return_type` of null means the return type is being inferred.
fn checkFunctionBody(
    self: *Checker,
    declaration: Ast.FunctionDeclaration,
    parameter_types: []const Type,
    expected_return_type: ?Type,
) Error!void {
    const view = try self.arena.create(Scope);
    view.* = .empty;
    // The module scope second, so a program function named like a prelude
    // function shadows it, as it does at the top level.
    for ([_]*const Scope{ self.prelude, self.module }) |source| {
        var entries = source.iterator();
        while (entries.next()) |entry| {
            var binding = entry.value_ptr.*;
            binding.assigned = true;
            try view.put(self.arena, entry.key_ptr.*, binding);
        }
    }

    const parameters = try self.arena.create(Scope);
    parameters.* = .empty;
    for (declaration.parameters, parameter_types) |parameter, parameter_type| {
        try parameters.put(self.arena, parameter.name, .{ .type = parameter_type, .assigned = true });
    }

    const outer_scopes = self.scopes;
    const outer_return_type = self.current_return_type;
    const outer_in_function = self.in_function;
    defer {
        self.scopes = outer_scopes;
        self.current_return_type = outer_return_type;
        self.in_function = outer_in_function;
    }

    self.scopes = .empty;
    try self.scopes.append(self.arena, view);
    try self.scopes.append(self.arena, parameters);
    self.current_return_type = expected_return_type;
    self.in_function = true;

    // The body's top level shares the parameters' scope, as in the resolver.
    try self.checkStatements(declaration.body.statements);
}

/// Merges the types of every `return` in a body being inferred. Section 4.4's
/// `Int`-to-`Float` widening applies, so `return 1` alongside `return 2.5`
/// infers `Float`. Kinds that cannot meet — including a bare `return`, which
/// arrives as `Nothing`, beside a valued one — make the answer ambiguous.
fn inferredReturnType(
    self: *Checker,
    types: []const Type,
    name: []const u8,
    span: Source.Span,
) Error!Type {
    if (types.len == 0) return .nothing;

    var result = types[0];
    for (types[1..]) |candidate| {
        if (candidate.assignableTo(result)) continue;
        if (result.assignableTo(candidate)) {
            result = candidate;
            continue;
        }
        try self.report(
            span,
            "the return type of `{s}` is ambiguous",
            .{name},
            "Add an explicit return type; this function returns more than one kind of value.",
        );
        return .invalid;
    }
    return result;
}

fn checkAllPathsReturn(self: *Checker, declaration: Ast.FunctionDeclaration, return_type: Type) Error!void {
    // Section 7.2: "Every reachable path in a value-producing function returns
    // a value." A function with no result has nothing to require, and one whose
    // type is already broken would only get a second report of the same
    // mistake.
    if (return_type.kind == .nothing or return_type.kind == .invalid) return;
    if (blockAlwaysReturns(declaration.body.statements)) return;
    try self.report(
        declaration.name_span,
        "not every path in `{s}` returns a value",
        .{declaration.name},
        "Add a `return` on every path, or restructure so every branch returns.",
    );
}

/// Whether a function can reach itself through the calls it makes, directly or
/// through other functions. Section 7.2 treats both as recursion.
fn isRecursive(self: *Checker, name: []const u8) Error!bool {
    var visited: Resolver.NameSet = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(self.arena, name);

    while (pending.pop()) |current| {
        const callees = self.facts.calls.get(current) orelse continue;
        var it = callees.keyIterator();
        while (it.next()) |callee| {
            if (std.mem.eql(u8, callee.*, name)) return true;
            if (visited.contains(callee.*)) continue;
            try visited.put(self.arena, callee.*, {});
            try pending.append(self.arena, callee.*);
        }
    }
    return false;
}

/// Every module variable a call to `name` can read: its own reads, and those
/// of every function reachable through its calls.
fn capturesOf(self: *Checker, name: []const u8) Error!Resolver.NameSet {
    if (self.captures.get(name)) |known| return known;

    var reads: Resolver.NameSet = .empty;
    var visited: Resolver.NameSet = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try visited.put(self.arena, name, {});
    try pending.append(self.arena, name);

    while (pending.pop()) |current| {
        if (self.facts.module_reads.get(current)) |own| {
            var it = own.keyIterator();
            while (it.next()) |read| try reads.put(self.arena, read.*, {});
        }
        if (self.facts.calls.get(current)) |callees| {
            var it = callees.keyIterator();
            while (it.next()) |callee| {
                if (visited.contains(callee.*)) continue;
                try visited.put(self.arena, callee.*, {});
                try pending.append(self.arena, callee.*);
            }
        }
    }

    try self.captures.put(self.arena, name, reads);
    return reads;
}

/// Section 7.1: "Hoisting never permits reading an uninitialized captured
/// variable." Checked where top-level code makes a call, against the module
/// scope as it stands there. Calls made inside a function are covered by the
/// top-level call that led to them, since a caller's captures include its
/// callees'.
fn checkCaptures(self: *Checker, call_span: Source.Span, callee: []const u8) Error!void {
    const reads = try self.capturesOf(callee);

    // Report the first unassigned name in alphabetical order, so the output
    // does not depend on hash order.
    var first: ?[]const u8 = null;
    var it = reads.keyIterator();
    while (it.next()) |read| {
        if (self.module.get(read.*)) |binding| {
            if (binding.assigned) continue;
        }
        if (first == null or std.mem.order(u8, read.*, first.?) == .lt) first = read.*;
    }

    const name = first orelse return;
    try self.reportWithHelp(
        call_span,
        "`{s}` reads `{s}`, which is not assigned yet here",
        .{ callee, name },
        "Move this call below the line that assigns `{s}`.",
        .{name},
    );
}

// Supporting checks.

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
    try self.reportWithHelp(
        span,
        "`{s}` may not have been assigned",
        .{name},
        "Assign `{s}` on every branch before reading it.",
        .{name},
    );
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

// Definite-assignment state.

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
    for (self.scopes.items, state) |scope, flags| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) binding.assigned = flags[index];
    }
}

fn intersect(self: *Checker, other: Snapshot) void {
    for (self.scopes.items, other) |scope, flags| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            binding.assigned = binding.assigned and flags[index];
        }
    }
}

fn markAllAssigned(self: *Checker) void {
    for (self.scopes.items) |scope| {
        var values = scope.valueIterator();
        while (values.next()) |binding| binding.assigned = true;
    }
}

// Expressions.

fn typeOf(self: *Checker, expression: *const Ast.Expression) Error!Type {
    return switch (expression.data) {
        .int_literal => .int,
        .float_literal => .float,
        .bool_literal => .bool,
        .nothing_literal => .nothing,

        .name => |name| blk: {
            // Missing only when the resolver already reported the name, or
            // while inferring early for a call that `checkCaptures` rejects.
            const binding = self.find(name) orelse break :blk .invalid;
            if (binding.is_function) {
                // Section 3.4 makes a bare function name its callable value.
                // Function values are deferred along with lambdas.
                try self.reportWithHelp(
                    expression.span,
                    "`{s}` is a function, and functions cannot be used as values yet",
                    .{name},
                    "Call it with parentheses, as in `{s}()`.",
                    .{name},
                );
                break :blk .invalid;
            }
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
        .call => |call| self.typeOfCall(expression, call),
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
///
/// Equality needs two values of the same type. Order needs numbers: `true <
/// false` has no meaning a reader would guess, so it is rejected rather than
/// given one.
fn typeOfComparison(self: *Checker, comparison: Ast.Expression.Comparison) Error!Type {
    var left_node = comparison.operands[0];
    var left = try self.typeOf(left_node);

    for (comparison.operators, comparison.operands[1..]) |operator, operand_node| {
        const right = try self.typeOf(operand_node);
        // The pair is the problem, so both sides are underlined.
        const pair: Source.Span = .{ .start = left_node.span.start, .end = operand_node.span.end };
        const numeric = left.isNumber() and right.isNumber();
        const unknown = left.kind == .invalid or right.kind == .invalid;

        if (!unknown and !numeric and left.kind != right.kind) {
            try self.report(
                pair,
                "{s} and {s} cannot be compared",
                .{ left.name(), right.name() },
                "`==` and `!=` compare two values of the same type, and Int and Float compare with each other.",
            );
        } else if (!unknown and !numeric and !operator.isEquality()) {
            try self.report(
                pair,
                "`{s}` needs numbers, but these are {s} values",
                .{ operator.lexeme(), left.name() },
                "Only numbers are ordered. Use `==` or `!=` to compare other values.",
            );
        }
        left = right;
        left_node = operand_node;
    }

    return .bool;
}

fn typeOfCall(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Type {
    if (call.callee.data != .name) {
        try self.report(
            call.callee.span,
            "this cannot be called",
            .{},
            "Only a function can be called, by writing its name followed by parentheses.",
        );
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    const name = call.callee.data.name;
    const binding = self.find(name) orelse {
        try self.typeArguments(call.arguments);
        return .invalid;
    };

    if (!binding.is_function) {
        try self.report(
            call.callee.span,
            "`{s}` is not a function",
            .{name},
            "Only a function can be called.",
        );
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    // A prelude function. Section 15.2's `print` accepts any number of values
    // and has no result.
    if (!self.declarations.contains(name)) {
        try self.typeArguments(call.arguments);
        return .nothing;
    }

    const signature = try self.signatureFor(name);

    if (call.arguments.len != signature.parameters.len) {
        const expected = signature.parameters.len;
        try self.report(
            call.callee.span,
            "`{s}` takes {d} argument{s}, but this call passes {d}",
            .{ name, expected, if (expected == 1) "" else "s", call.arguments.len },
            "Match the number of arguments to the function's parameters.",
        );
        try self.typeArguments(call.arguments);
    } else {
        for (call.arguments, signature.parameters, signature.parameter_names) |argument, expected, parameter_name| {
            const actual = try self.typeOf(argument);
            if (!actual.assignableTo(expected)) {
                try self.report(
                    argument.span,
                    "this is {s}, but parameter `{s}` of `{s}` needs {s}",
                    .{ actual.name(), parameter_name, name, expected.name() },
                    "Pass a value of the expected type, or convert it first.",
                );
            }
        }
    }

    if (!self.in_function) try self.checkCaptures(expression.span, name);
    return signature.return_type;
}

fn typeArguments(self: *Checker, arguments: []const *const Ast.Expression) Error!void {
    for (arguments) |argument| _ = try self.typeOf(argument);
}

// Control-flow shape, computed from the AST alone.

/// Whether every path through a block ends in `return`. Once one statement
/// definitely returns, what follows it cannot change the answer.
fn blockAlwaysReturns(statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        if (stmtAlwaysReturns(statement)) return true;
    }
    return false;
}

fn stmtAlwaysReturns(statement: Ast.Statement) bool {
    return switch (statement.data) {
        .return_statement => true,
        .conditional => |conditional| blk: {
            if (!blockAlwaysReturns(conditional.then_block.statements)) break :blk false;
            const otherwise = conditional.otherwise orelse break :blk false;
            break :blk switch (otherwise) {
                .block => |block| blockAlwaysReturns(block.statements),
                .chained => |chained| stmtAlwaysReturns(chained.*),
            };
        },
        .expression, .declaration, .assignment, .function_declaration => false,
    };
}

/// Whether a body contains a `return` carrying a value anywhere, which decides
/// whether a function without an annotation has anything to infer.
fn blockHasValueReturn(statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        if (statementHasValueReturn(statement)) return true;
    }
    return false;
}

fn statementHasValueReturn(statement: Ast.Statement) bool {
    return switch (statement.data) {
        .return_statement => |return_statement| return_statement.value != null,
        .conditional => |conditional| blk: {
            if (blockHasValueReturn(conditional.then_block.statements)) break :blk true;
            const otherwise = conditional.otherwise orelse break :blk false;
            break :blk switch (otherwise) {
                .block => |block| blockHasValueReturn(block.statements),
                .chained => |chained| statementHasValueReturn(chained.*),
            };
        },
        .expression, .declaration, .assignment, .function_declaration => false,
    };
}
