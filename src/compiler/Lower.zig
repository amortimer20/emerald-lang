//! Lowering: the checked syntax tree to the IR (docs/compiler-design-plan.md,
//! decision 3). The checker has proved the program well typed, so this only
//! decides how each construct runs: which operations, in which blocks, with
//! which checks. Types come from the checker's `expression_types`.
//!
//! What the compiler cannot compile yet stops lowering with `Unsupported`,
//! naming the construct and where it is, so `emerald build` can say so plainly
//! rather than produce a program that behaves differently. Each slice of the
//! plan shrinks what that covers.

const std = @import("std");
const Ast = @import("../Ast.zig");
const Source = @import("../Source.zig");
const Type = @import("../Type.zig");
const Checker = @import("../Checker.zig");
const Resolver = @import("../Resolver.zig");
const Ir = @import("Ir.zig");
const Arithmetic = @import("runtime").Operations.Arithmetic;

const Lower = @This();

arena: std.mem.Allocator,
source: *const Source,
file: u32,
checked: *const Checker.Checked,
facts: *const Resolver.Facts,
functions: std.ArrayList(Ir.Function) = .empty,
function_keys: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
globals: std.ArrayList(Ir.Global) = .empty,
global_keys: std.StringHashMapUnmanaged(Ir.GlobalIndex) = .empty,
sites: std.ArrayList(Source.Span) = .empty,
/// What stopped lowering, once something has.
unsupported: ?Unsupported = null,

pub const Unsupported = struct {
    span: Source.Span,
    /// What cannot be compiled yet, as a phrase: "a list", "a nested function".
    what: []const u8,
};

pub const Error = error{ OutOfMemory, Unsupported };

const FunctionInfo = struct {
    index: Ir.FunctionIndex,
    parameters: []const Ir.Type,
    result: Ir.Type,
};

/// Lowers the entry file `file` of a checked project. On `error.Unsupported`,
/// `unsupported` says what and where.
pub fn lower(self: *Lower, program: Ast.Program) Error!Ir.Program {
    // Functions first, so a call can come before the function it calls, and
    // module-level variables, which any function may read.
    try self.functions.append(self.arena, undefined); // the entry, built last
    for (program.statements) |statement| switch (statement.data) {
        .function_declaration => |function| try self.declareFunction(function),
        .declaration => |declaration| try self.declareGlobal(declaration),
        else => {},
    };
    for (program.statements) |statement| {
        if (statement.data == .function_declaration) try self.lowerFunction(statement.data.function_declaration);
    }
    var entry: Builder = try .init(self, "", .nothing, &.{}, &.{});
    entry.top_level = true;
    for (program.statements) |statement| {
        if (statement.data == .function_declaration) continue;
        try entry.statement(statement);
    }
    self.functions.items[0] = try entry.finish();
    return .{ .functions = self.functions.items, .globals = self.globals.items, .sites = self.sites.items };
}

fn fail(self: *Lower, span: Source.Span, what: []const u8) Error {
    self.unsupported = .{ .span = span, .what = what };
    return error.Unsupported;
}

fn keyOf(self: *Lower, name: []const u8) []const u8 {
    return self.facts.keyFor(self.file, name) orelse name;
}

fn site(self: *Lower, span: Source.Span) Error!Ir.Site {
    try self.sites.append(self.arena, span);
    return @intCast(self.sites.items.len - 1);
}

fn line(self: *Lower, span: Source.Span) u32 {
    return self.source.location(span.start).line;
}

/// The IR type of a checked type, or `null` for one slice 2 cannot hold.
fn irType(checked: Type) ?Ir.Type {
    if (checked.optional) return null;
    return switch (checked.kind) {
        .int => .int,
        .float => .float,
        .bool => .bool,
        .nothing => .nothing,
        else => null,
    };
}

fn annotationType(self: *Lower, annotation: Ast.TypeExpression) Error!Ir.Type {
    const plain = annotation.element == null and annotation.key == null and annotation.signature == null and
        annotation.positions == null and annotation.arguments.len == 0 and annotation.question_span == null and
        !annotation.set and !annotation.task and !annotation.channel;
    if (plain) {
        if (std.mem.eql(u8, annotation.name, "Int")) return .int;
        if (std.mem.eql(u8, annotation.name, "Float")) return .float;
        if (std.mem.eql(u8, annotation.name, "Bool")) return .bool;
    }
    return self.fail(annotation.span, "a value of this type");
}

fn expressionType(self: *Lower, expression: *const Ast.Expression) Error!Ir.Type {
    const found = self.checked.expression_types.get(expression) orelse return self.fail(expression.span, "this expression");
    return irType(found.type) orelse self.fail(expression.span, "a value of this type");
}

fn declareFunction(self: *Lower, function: Ast.FunctionDeclaration) Error!void {
    if (function.type_parameters.len != 0) return self.fail(function.name_span, "a generic function");
    if (function.test_span != null) return self.fail(function.name_span, "a test");
    const parameters = try self.arena.alloc(Ir.Type, function.parameters.len);
    for (function.parameters, parameters) |parameter, *type_| {
        if (parameter.default != null) return self.fail(parameter.name_span, "a parameter with a default");
        type_.* = try self.annotationType(parameter.annotation);
    }
    const result: Ir.Type = if (function.return_annotation) |annotation| try self.annotationType(annotation) else .nothing;
    try self.function_keys.put(self.arena, self.keyOf(function.name), .{
        .index = @intCast(self.functions.items.len),
        .parameters = parameters,
        .result = result,
    });
    try self.functions.append(self.arena, undefined);
}

fn declareGlobal(self: *Lower, declaration: Ast.Declaration) Error!void {
    const type_: Ir.Type = if (declaration.annotation) |annotation|
        try self.annotationType(annotation)
    else if (declaration.initializer) |initializer|
        try self.expressionType(initializer)
    else
        return self.fail(declaration.name_span, "a declaration without a type");
    try self.global_keys.put(self.arena, self.keyOf(declaration.name), @intCast(self.globals.items.len));
    try self.globals.append(self.arena, .{ .name = declaration.name, .type = type_ });
}

fn lowerFunction(self: *Lower, function: Ast.FunctionDeclaration) Error!void {
    const info = self.function_keys.get(self.keyOf(function.name)).?;
    const names = try self.arena.alloc([]const u8, function.parameters.len);
    for (function.parameters, names) |parameter, *name| name.* = parameter.name;
    var builder: Builder = try .init(self, function.name, info.result, info.parameters, names);
    try builder.block(function.body);
    self.functions.items[info.index] = try builder.finish();
}

/// What a value evaluates to: where to read it, and its type.
const Value = struct {
    operand: Ir.Operand,
    type: Ir.Type,
};

const Loop = struct {
    break_to: Ir.BlockIndex,
    continue_to: Ir.BlockIndex,
};

const BlockBuilder = struct {
    instructions: std.ArrayList(Ir.Instruction) = .empty,
    terminator: ?Ir.Terminator = null,
};

/// Builds one function's blocks.
const Builder = struct {
    owner: *Lower,
    name: []const u8,
    result: Ir.Type,
    parameter_count: u32,
    locals: std.ArrayList(Ir.LocalInfo) = .empty,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    current: Ir.BlockIndex = 0,
    /// Each scope maps a name written in it to its local, innermost last.
    scopes: std.ArrayList(std.StringHashMapUnmanaged(Ir.Local)) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    /// Whether this is the entry, whose outermost declarations are the
    /// module's variables.
    top_level: bool = false,

    fn init(owner: *Lower, name: []const u8, result: Ir.Type, parameters: []const Ir.Type, names: []const []const u8) Error!Builder {
        var self: Builder = .{ .owner = owner, .name = name, .result = result, .parameter_count = @intCast(parameters.len) };
        try self.blocks.append(owner.arena, .{});
        try self.scopes.append(owner.arena, .empty);
        for (parameters, names) |type_, written| {
            const local = try self.newLocal(written, type_);
            try self.scopes.items[0].put(owner.arena, written, local);
        }
        return self;
    }

    fn finish(self: *Builder) Error!Ir.Function {
        // Falling off the end returns nothing; the checker has proved a
        // function with a result returns before it gets there.
        self.terminate(.{ .@"return" = null });
        const blocks = try self.owner.arena.alloc(Ir.Block, self.blocks.items.len);
        for (self.blocks.items, blocks) |built, *out| out.* = .{
            .instructions = built.instructions.items,
            .terminator = built.terminator.?,
        };
        return .{
            .name = self.name,
            .locals = self.locals.items,
            .parameter_count = self.parameter_count,
            .result = self.result,
            .blocks = blocks,
        };
    }

    fn arena(self: *Builder) std.mem.Allocator {
        return self.owner.arena;
    }

    fn newLocal(self: *Builder, name: []const u8, type_: Ir.Type) Error!Ir.Local {
        try self.locals.append(self.arena(), .{ .name = name, .type = type_ });
        return @intCast(self.locals.items.len - 1);
    }

    fn temporary(self: *Builder, type_: Ir.Type) Error!Ir.Local {
        return self.newLocal("", type_);
    }

    fn newBlock(self: *Builder) Error!Ir.BlockIndex {
        try self.blocks.append(self.arena(), .{});
        return @intCast(self.blocks.items.len - 1);
    }

    fn switchTo(self: *Builder, index: Ir.BlockIndex) void {
        self.current = index;
    }

    /// Ends the current block, unless something already ended it, as a
    /// `return` inside an `if` does.
    fn terminate(self: *Builder, terminator: Ir.Terminator) void {
        const current = &self.blocks.items[self.current];
        if (current.terminator == null) current.terminator = terminator;
    }

    fn emit(self: *Builder, span: Source.Span, data: Ir.Instruction.Data) Error!void {
        const current = &self.blocks.items[self.current];
        // Code after a `return`, `break` or `continue` cannot run.
        if (current.terminator != null) return;
        try current.instructions.append(self.arena(), .{ .line = self.owner.line(span), .data = data });
    }

    fn pushScope(self: *Builder) Error!void {
        try self.scopes.append(self.arena(), .empty);
    }

    fn popScope(self: *Builder) void {
        _ = self.scopes.pop();
    }

    fn find(self: *Builder, name: []const u8) ?Ir.Local {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].get(name)) |local| return local;
        }
        return null;
    }

    /// The place a name written here refers to.
    fn place(self: *Builder, name: []const u8, span: Source.Span) Error!struct { place: Ir.Place, type: Ir.Type } {
        if (self.find(name)) |local| return .{ .place = .{ .local = local }, .type = self.locals.items[local].type };
        if (self.owner.global_keys.get(self.owner.keyOf(name))) |global| {
            return .{ .place = .{ .global = global }, .type = self.owner.globals.items[global].type };
        }
        return self.owner.fail(span, "this name");
    }

    fn block(self: *Builder, body: Ast.Block) Error!void {
        try self.pushScope();
        defer self.popScope();
        for (body.statements) |one| try self.statement(one);
    }

    fn statement(self: *Builder, one: Ast.Statement) Error!void {
        switch (one.data) {
            .expression => |called| {
                if (called.data != .call) return self.owner.fail(called.span, "this statement");
                _ = try self.call(called, called.data.call, true);
            },
            .declaration => |declared| try self.declaration(declared),
            .assignment => |assigned| try self.assignment(one.span, assigned),
            .conditional => |branching| try self.conditional(branching),
            .while_loop => |loop| try self.whileLoop(loop),
            .for_loop => |loop| try self.forLoop(loop),
            .break_statement => {
                self.terminate(.{ .jump = self.loops.items[self.loops.items.len - 1].break_to });
            },
            .continue_statement => {
                self.terminate(.{ .jump = self.loops.items[self.loops.items.len - 1].continue_to });
            },
            .return_statement => |returned| {
                if (returned.value) |value| {
                    const result = try self.convert(try self.expression(value), self.result, value.span);
                    self.terminate(.{ .@"return" = result });
                } else self.terminate(.{ .@"return" = null });
            },
            .function_declaration => |function| return self.owner.fail(function.name_span, "a nested function"),
            .struct_declaration => |declared| return self.owner.fail(declared.name_span, "a type declaration"),
            .raise_statement => |raised| return self.owner.fail(raised.keyword_span, "`raise`"),
            .try_statement => |tried| return self.owner.fail(tried.keyword_span, "`try`"),
            .assert_statement => |assertion| return self.owner.fail(assertion.keyword_span, "`assert`"),
            .case_statement => |case| return self.owner.fail(case.keyword_span, "`case`"),
            .destructuring, .destructuring_assignment => return self.owner.fail(one.span, "destructuring"),
        }
    }

    fn declaration(self: *Builder, declaration_: Ast.Declaration) Error!void {
        // The entry's outermost declarations are module variables, which
        // functions can read; every other declaration is a local.
        if (self.top_level and self.scopes.items.len == 1) {
            const global = self.owner.global_keys.get(self.owner.keyOf(declaration_.name)).?;
            if (declaration_.initializer) |initializer| {
                const type_ = self.owner.globals.items[global].type;
                const value = try self.convert(try self.expression(initializer), type_, initializer.span);
                try self.emit(initializer.span, .{ .move = .{ .destination = .{ .global = global }, .source = value } });
            }
            return;
        }
        const type_: Ir.Type = if (declaration_.annotation) |annotation|
            try self.owner.annotationType(annotation)
        else if (declaration_.initializer) |initializer|
            try self.owner.expressionType(initializer)
        else
            return self.owner.fail(declaration_.name_span, "a declaration without a type");
        // The initializer is evaluated before the name exists, so it reads
        // any outer variable of the same name.
        const initial = if (declaration_.initializer) |initializer|
            try self.convert(try self.expression(initializer), type_, initializer.span)
        else
            null;
        const local = try self.newLocal(declaration_.name, type_);
        try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), declaration_.name, local);
        if (initial) |value| try self.emit(declaration_.name_span, .{ .move = .{ .destination = .{ .local = local }, .source = value } });
    }

    fn assignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment) Error!void {
        if (assignment_.steps.len != 0) return self.owner.fail(assignment_.target_span, "assigning into a collection or a field");
        const target = try self.place(assignment_.name, assignment_.name_span);
        if (assignment_.operation) |operation| {
            // Read once, before the right side runs, which could change it.
            const current = try self.read(target.place, target.type, span);
            const right = try self.expression(assignment_.value);
            const result = try self.binary(span, operation, current, right);
            const stored = try self.convert(result, target.type, span);
            try self.emit(span, .{ .move = .{ .destination = target.place, .source = stored } });
            return;
        }
        const value = try self.convert(try self.expression(assignment_.value), target.type, assignment_.value.span);
        try self.emit(span, .{ .move = .{ .destination = target.place, .source = value } });
    }

    fn conditional(self: *Builder, branch: Ast.If) Error!void {
        const condition = try self.expression(branch.condition);
        const then_block = try self.newBlock();
        const after = try self.newBlock();
        const otherwise_block = if (branch.otherwise != null) try self.newBlock() else after;
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = then_block, .otherwise = otherwise_block } });

        self.switchTo(then_block);
        try self.block(branch.then_block);
        self.terminate(.{ .jump = after });

        if (branch.otherwise) |otherwise| {
            self.switchTo(otherwise_block);
            switch (otherwise) {
                .block => |body| try self.block(body),
                .chained => |chained| try self.statement(chained.*),
            }
            self.terminate(.{ .jump = after });
        }
        self.switchTo(after);
    }

    fn whileLoop(self: *Builder, loop: Ast.While) Error!void {
        const head = try self.newBlock();
        const body = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .jump = head });
        self.switchTo(head);
        const condition = try self.expression(loop.condition);
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = body, .otherwise = after } });
        self.switchTo(body);
        try self.loops.append(self.arena(), .{ .break_to = after, .continue_to = head });
        try self.block(loop.body);
        _ = self.loops.pop();
        self.terminate(.{ .jump = head });
        self.switchTo(after);
    }

    /// Section 6.4's `for` over a written range. The counter stops on
    /// reaching the last value rather than stepping past it, so a range that
    /// ends at the largest `Int` does not overflow, as `Range` itself does.
    fn forLoop(self: *Builder, loop: Ast.For) Error!void {
        if (loop.pattern != null) return self.owner.fail(loop.name_span, "a `for` with a pattern");
        if (loop.iterable.data != .range) return self.owner.fail(loop.iterable.span, "a `for` over anything but a written range");
        const range = loop.iterable.data.range;
        const start = try self.convert(try self.expression(range.start), .int, range.start.span);
        const end = try self.convert(try self.expression(range.end), .int, range.end.span);
        const span = loop.iterable.span;

        // `first` and `last`, or an empty range: `a..b` holds `b`, `a..<b`
        // stops before it.
        const current = try self.temporary(.int);
        const last = try self.temporary(.int);
        try self.emit(span, .{ .move = .{ .destination = .{ .local = current }, .source = start } });
        const empty = try self.temporary(.bool);
        try self.emit(span, .{ .compare = .{
            .operator = if (range.inclusive) .greater else .greater_equal,
            .kind = .int,
            .destination = .{ .local = empty },
            .left = start,
            .right = end,
        } });
        const setup = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = .{ .local = empty }, .then = after, .otherwise = setup } });
        self.switchTo(setup);
        if (range.inclusive) {
            try self.emit(span, .{ .move = .{ .destination = .{ .local = last }, .source = end } });
        } else {
            // `end` is above `start`, so this cannot overflow.
            try self.emit(span, .{ .int_arithmetic = .{ .operator = .subtract, .destination = .{ .local = last }, .left = end, .right = .{ .int = 1 }, .site = try self.owner.site(span) } });
        }
        const body = try self.newBlock();
        const step = try self.newBlock();
        self.terminate(.{ .jump = body });

        self.switchTo(body);
        try self.pushScope();
        const variable = try self.newLocal(loop.name, .int);
        try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), loop.name, variable);
        try self.emit(loop.name_span, .{ .move = .{ .destination = .{ .local = variable }, .source = .{ .local = current } } });
        try self.loops.append(self.arena(), .{ .break_to = after, .continue_to = step });
        try self.block(loop.body);
        _ = self.loops.pop();
        self.popScope();
        self.terminate(.{ .jump = step });

        self.switchTo(step);
        const done = try self.temporary(.bool);
        try self.emit(span, .{ .compare = .{ .operator = .equal, .kind = .int, .destination = .{ .local = done }, .left = .{ .local = current }, .right = .{ .local = last } } });
        const advance = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = .{ .local = done }, .then = after, .otherwise = advance } });
        self.switchTo(advance);
        try self.emit(span, .{ .int_arithmetic = .{ .operator = .add, .destination = .{ .local = current }, .left = .{ .local = current }, .right = .{ .int = 1 }, .site = try self.owner.site(span) } });
        self.terminate(.{ .jump = body });

        self.switchTo(after);
    }

    /// The value at `place` now. A module variable is copied, since a call
    /// later in the same expression could change it before it is used; a
    /// local cannot change that way until slice 3 compiles closures.
    fn read(self: *Builder, at: Ir.Place, type_: Ir.Type, span: Source.Span) Error!Value {
        switch (at) {
            .local => |local| return .{ .operand = .{ .local = local }, .type = type_ },
            .global => |global| {
                const copy = try self.temporary(type_);
                try self.emit(span, .{ .move = .{ .destination = .{ .local = copy }, .source = .{ .global = global } } });
                return .{ .operand = .{ .local = copy }, .type = type_ };
            },
        }
    }

    /// `value` as `target`, widening an `Int` where a `Float` is expected.
    fn convert(self: *Builder, value: Value, target: Ir.Type, span: Source.Span) Error!Ir.Operand {
        if (value.type == target) return value.operand;
        if (value.type == .int and target == .float) {
            if (value.operand == .int) return .{ .float = @floatFromInt(value.operand.int) };
            const widened = try self.temporary(.float);
            try self.emit(span, .{ .widen = .{ .destination = .{ .local = widened }, .operand = value.operand } });
            return .{ .local = widened };
        }
        return self.owner.fail(span, "this conversion");
    }

    fn expression(self: *Builder, expression_: *const Ast.Expression) Error!Value {
        return switch (expression_.data) {
            .int_literal => |value| .{ .operand = .{ .int = value }, .type = .int },
            .float_literal => |value| .{ .operand = .{ .float = value }, .type = .float },
            .bool_literal => |value| .{ .operand = .{ .bool = value }, .type = .bool },
            .name => |name| blk: {
                const found = try self.place(name, expression_.span);
                break :blk self.read(found.place, found.type, expression_.span);
            },
            .unary => |operation| self.unary(expression_.span, operation),
            .binary => |operation| blk: {
                if (self.owner.checked.operator_calls.contains(expression_)) return self.owner.fail(expression_.span, "an operator defined by a type");
                const left = try self.expression(operation.left);
                const right = try self.expression(operation.right);
                break :blk self.binary(expression_.span, operation.operator, left, right);
            },
            .logical => |operation| self.logical(expression_, operation),
            .comparison => |chain| self.comparison(expression_, chain),
            .if_expression => |choice| self.ifExpression(expression_, choice),
            .call => |call_| (try self.call(expression_, call_, false)) orelse self.owner.fail(expression_.span, "using the result of this call"),
            .string_literal, .interpolation => self.owner.fail(expression_.span, "a String value"),
            .nothing_literal => self.owner.fail(expression_.span, "`nothing`"),
            .list_literal => self.owner.fail(expression_.span, "a list"),
            .dictionary_literal => self.owner.fail(expression_.span, "a dictionary"),
            .tuple_literal => self.owner.fail(expression_.span, "a tuple"),
            .range => self.owner.fail(expression_.span, "a range outside a `for`"),
            .lambda => self.owner.fail(expression_.span, "a block"),
            .member => self.owner.fail(expression_.span, "a member"),
            .index, .slice => self.owner.fail(expression_.span, "indexing"),
            .case_expression => self.owner.fail(expression_.span, "`case`"),
            .enum_value, .type_literal => self.owner.fail(expression_.span, "a type's value"),
            .type_test => self.owner.fail(expression_.span, "`is`"),
        };
    }

    fn unary(self: *Builder, span: Source.Span, unary_: Ast.Expression.Unary) Error!Value {
        const operand = try self.expression(unary_.operand);
        switch (unary_.operator) {
            .not => {
                const result = try self.temporary(.bool);
                try self.emit(span, .{ .not = .{ .destination = .{ .local = result }, .operand = operand.operand } });
                return .{ .operand = .{ .local = result }, .type = .bool };
            },
            .negate => {
                const result = try self.temporary(operand.type);
                switch (operand.type) {
                    .int => try self.emit(span, .{ .negate_int = .{ .destination = .{ .local = result }, .operand = operand.operand, .site = try self.owner.site(span) } }),
                    .float => try self.emit(span, .{ .negate_float = .{ .destination = .{ .local = result }, .operand = operand.operand } }),
                    else => return self.owner.fail(span, "negating this value"),
                }
                return .{ .operand = .{ .local = result }, .type = operand.type };
            },
        }
    }

    /// Section 5.3: two `Int`s give an `Int`, except under `/`; any `Float`
    /// makes the operation a `Float` one.
    fn binary(self: *Builder, span: Source.Span, operator: Arithmetic, left: Value, right: Value) Error!Value {
        if (!isNumber(left.type) or !isNumber(right.type)) return self.owner.fail(span, "this operation");
        if (left.type == .int and right.type == .int and operator != .divide) {
            const result = try self.temporary(.int);
            try self.emit(span, .{ .int_arithmetic = .{ .operator = operator, .destination = .{ .local = result }, .left = left.operand, .right = right.operand, .site = try self.owner.site(span) } });
            return .{ .operand = .{ .local = result }, .type = .int };
        }
        const left_float = try self.convert(left, .float, span);
        const right_float = try self.convert(right, .float, span);
        const result = try self.temporary(.float);
        try self.emit(span, .{ .float_arithmetic = .{ .operator = operator, .destination = .{ .local = result }, .left = left_float, .right = right_float, .site = try self.owner.site(span) } });
        return .{ .operand = .{ .local = result }, .type = .float };
    }

    /// `and` and `or`, which evaluate the right side only when the left
    /// does not decide the answer.
    fn logical(self: *Builder, expression_: *const Ast.Expression, logical_: Ast.Expression.Logical) Error!Value {
        const result = try self.temporary(.bool);
        const left = try self.expression(logical_.left);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = left.operand } });
        const right_block = try self.newBlock();
        const after = try self.newBlock();
        switch (logical_.operator) {
            .conjunction => self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = right_block, .otherwise = after } }),
            .disjunction => self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = after, .otherwise = right_block } }),
        }
        self.switchTo(right_block);
        const right = try self.expression(logical_.right);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = right.operand } });
        self.terminate(.{ .jump = after });
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = .bool };
    }

    /// Section 5.2's chain, `a < b < c`: each middle operand evaluated once,
    /// and the chain stopping at the first link that is false.
    fn comparison(self: *Builder, expression_: *const Ast.Expression, comparison_: Ast.Expression.Comparison) Error!Value {
        const result = try self.temporary(.bool);
        const after = try self.newBlock();
        var left = try self.expression(comparison_.operands[0]);
        for (comparison_.operators, comparison_.operands[1..], 0..) |operator, operand, position| {
            const right = try self.expression(operand);
            const kind: Ir.Instruction.Comparison = switch (left.type) {
                .int => switch (right.type) {
                    .int => .int,
                    .float => .int_float,
                    else => return self.owner.fail(expression_.span, "this comparison"),
                },
                .float => switch (right.type) {
                    .float => .float,
                    .int => .float_int,
                    else => return self.owner.fail(expression_.span, "this comparison"),
                },
                .bool => if (right.type == .bool and operator.isEquality()) .bool else return self.owner.fail(expression_.span, "this comparison"),
                .nothing => return self.owner.fail(expression_.span, "this comparison"),
            };
            try self.emit(expression_.span, .{ .compare = .{ .operator = operator, .kind = kind, .destination = .{ .local = result }, .left = left.operand, .right = right.operand } });
            if (position + 1 < comparison_.operators.len) {
                const next = try self.newBlock();
                self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = next, .otherwise = after } });
                self.switchTo(next);
            }
            left = right;
        }
        self.terminate(.{ .jump = after });
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = .bool };
    }

    fn ifExpression(self: *Builder, expression_: *const Ast.Expression, choice: Ast.Expression.IfExpression) Error!Value {
        const type_ = try self.owner.expressionType(expression_);
        const result = try self.temporary(type_);
        const condition = try self.expression(choice.condition);
        const then_block = try self.newBlock();
        const else_block = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = then_block, .otherwise = else_block } });
        try self.arm(then_block, choice.then_value, result, type_, after);
        try self.arm(else_block, choice.else_value, result, type_, after);
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = type_ };
    }

    fn arm(self: *Builder, start: Ir.BlockIndex, value: *const Ast.Expression, result: Ir.Local, type_: Ir.Type, after: Ir.BlockIndex) Error!void {
        self.switchTo(start);
        const converted = try self.convert(try self.expression(value), type_, value.span);
        try self.emit(value.span, .{ .move = .{ .destination = .{ .local = result }, .source = converted } });
        self.terminate(.{ .jump = after });
    }

    /// A call to `print`, `write` or a function of the program. Gives the
    /// result, or null when the call gives nothing.
    fn call(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, discarded: bool) Error!?Value {
        if (call_.callee.data != .name) return self.owner.fail(call_.callee.span, "calling this");
        if (call_.names.len != 0) return self.owner.fail(expression_.span, "named arguments");
        const name = call_.callee.data.name;
        if (self.find(name) == null) {
            if (self.owner.function_keys.get(self.owner.keyOf(name))) |info| {
                if (call_.arguments.len != info.parameters.len) return self.owner.fail(expression_.span, "leaving out an argument");
                const arguments = try self.arena().alloc(Ir.Operand, call_.arguments.len);
                for (call_.arguments, info.parameters, arguments) |argument, parameter, *out| {
                    out.* = try self.convert(try self.expression(argument), parameter, argument.span);
                }
                const destination: ?Ir.Local = if (info.result == .nothing or discarded) null else try self.temporary(info.result);
                try self.emit(expression_.span, .{ .call = .{
                    .function = info.index,
                    .arguments = arguments,
                    .destination = if (destination) |local| .{ .local = local } else null,
                    .site = try self.owner.site(expression_.span),
                } });
                return if (destination) |local| .{ .operand = .{ .local = local }, .type = info.result } else null;
            }
            // Section 15.2's `print` and `write` are built in rather than
            // declared, so the resolver keys them only when the program
            // declares a name of its own that hides them.
            if (self.owner.facts.keyFor(self.owner.file, name) == null) {
                if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "write")) {
                    try self.print(expression_, call_, std.mem.eql(u8, name, "print"));
                    return null;
                }
            }
        }
        return self.owner.fail(expression_.span, "calling this function");
    }

    /// Section 15.2: the arguments' display, separated by spaces, and for
    /// `print` the end of the line. Every argument is evaluated before any of
    /// the line is written, as the interpreter builds the line first, so a
    /// call among the arguments prints its own output ahead of it.
    fn print(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, newline: bool) Error!void {
        var parts: std.ArrayList(Ir.Instruction.Write) = .empty;
        for (call_.arguments, 0..) |argument, position| {
            if (position != 0) try parts.append(self.arena(), .{ .text = " " });
            switch (argument.data) {
                .interpolation => |pieces| for (pieces) |piece| switch (piece) {
                    .text => |text| try parts.append(self.arena(), .{ .text = text }),
                    .expression => |inner| try parts.append(self.arena(), try self.display(inner)),
                },
                else => try parts.append(self.arena(), try self.display(argument)),
            }
        }
        if (newline) try parts.append(self.arena(), .{ .text = "\n" });
        for (parts.items) |part| try self.emit(expression_.span, .{ .write = part });
    }

    fn display(self: *Builder, expression_: *const Ast.Expression) Error!Ir.Instruction.Write {
        if (expression_.data == .string_literal) return .{ .text = expression_.data.string_literal };
        const value = try self.expression(expression_);
        return switch (value.type) {
            .int => .{ .int = value.operand },
            .float => .{ .float = value.operand },
            .bool => .{ .bool = value.operand },
            .nothing => .{ .text = "nothing" },
        };
    }
};

fn operandOf(place: Ir.Place) Ir.Operand {
    return switch (place) {
        .local => |local| .{ .local = local },
        .global => |global| .{ .global = global },
    };
}

fn isNumber(type_: Ir.Type) bool {
    return type_ == .int or type_ == .float;
}
