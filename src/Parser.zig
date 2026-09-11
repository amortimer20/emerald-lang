//! Turns tokens into a syntax tree.
//!
//! The precedence here is section 5.3's, and two of its rules are easy to get
//! backwards. Exponentiation binds more tightly than unary minus, so `-2 ** 2`
//! is `-(2 ** 2)` rather than `(-2) ** 2`. Exponentiation also associates right
//! to left, so `2 ** 3 ** 2` is `2 ** (3 ** 2)`.
//!
//! Both fall out of one grammar rule: the right operand of `**` is parsed as a
//! unary expression rather than as another power. That makes the operator
//! right-associative and simultaneously lets `2 ** -3` parse, while a leading
//! `-` still wraps the whole power because unary sits above it.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Lexer = @import("Lexer.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const Parser = @This();

/// A parsed file. The tree and every diagnostic live in one arena, so releasing
/// the result is a single call.
pub const Parsed = struct {
    arena_state: std.heap.ArenaAllocator,
    program: Ast.Program,
    diagnostics: []const Diagnostic,

    pub fn ok(self: Parsed) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Parsed) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

arena: std.mem.Allocator,
source: *const Source,
tokens: []const Token,
index: usize = 0,
diagnostics: std.ArrayList(Diagnostic) = .empty,
/// Nested function declarations are deferred, so `func` is legal only while
/// this is true. Set false for the duration of any block body.
at_top_level: bool = true,
/// Open parentheses and braces. Section 3.4 guarantees at least 256.
nesting: u32 = 0,
/// Recursion that opens no delimiter: prefix `-` and `not`, the right side of
/// `**`, and `else if`. Bounded separately so that it cannot eat into the 256
/// delimiters section 3.4 promises, and so a very long chain of any of them is
/// still a diagnostic rather than a crash.
recursion: u32 = 0,

/// Section 3.4: "An implementation accepts at least 256 nested syntactic
/// delimiters or declarations and checks its nesting budget before consuming
/// the host stack." Exactly the minimum, so no program can come to depend on
/// more here than every implementation accepts.
pub const max_nesting = 256;

/// Every later pass walks an expression recursively, and a long flat chain
/// such as `1 + 1 + ... + 1` builds a tree as tall as it is long without
/// nesting anything, so height is bounded here too. Far beyond anything written
/// by hand, and well within the stack every pass runs on.
pub const max_expression_depth = 10_000;

const Error = error{ParseFailed} || std.mem.Allocator.Error;

pub fn parse(gpa: std.mem.Allocator, source: *const Source, tokens: []const Token) !Parsed {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser: Parser = .{ .arena = arena, .source = source, .tokens = tokens };

    var statements: std.ArrayList(Ast.Statement) = .empty;
    while (true) {
        parser.skipSeparators();
        if (parser.peek().kind == .eof) break;

        if (parser.parseStatement()) |statement| {
            try statements.append(arena, statement);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Resume at the next line so one mistake does not cascade, which is
            // what section 17.2 asks for.
            error.ParseFailed => parser.skipToNextStatement(),
        }
    }

    // Both allocations have to finish before the arena is copied into the
    // result, because copying it snapshots the list of blocks it owns.
    const owned_statements = try statements.toOwnedSlice(arena);
    const owned_diagnostics = try parser.diagnostics.toOwnedSlice(arena);

    return .{
        .arena_state = arena_state,
        .program = .{ .statements = owned_statements },
        .diagnostics = owned_diagnostics,
    };
}

// Token access. Documentation comments are not attached to anything yet, so the
// parser steps over them; the declaration slice is where they start to matter.

fn peek(self: *Parser) Token {
    var at = self.index;
    while (at < self.tokens.len and self.tokens[at].kind == .doc_comment) at += 1;
    return self.tokens[at];
}

fn advance(self: *Parser) Token {
    while (self.tokens[self.index].kind == .doc_comment) self.index += 1;
    const token = self.tokens[self.index];
    if (token.kind != .eof) self.index += 1;
    return token;
}

fn peekAfterNext(self: *Parser) Token {
    var at = self.index;
    while (self.tokens[at].kind == .doc_comment) at += 1;
    if (self.tokens[at].kind == .eof) return self.tokens[at];
    at += 1;
    while (self.tokens[at].kind == .doc_comment) at += 1;
    return self.tokens[at];
}

fn check(self: *Parser, kind: Token.Kind) bool {
    return self.peek().kind == kind;
}

fn match(self: *Parser, kind: Token.Kind) ?Token {
    if (!self.check(kind)) return null;
    return self.advance();
}

fn text(self: Parser, token: Token) []const u8 {
    return self.source.text[token.span.start..token.span.end];
}

fn skipSeparators(self: *Parser) void {
    while (self.check(.newline)) _ = self.advance();
}

/// The next token that is neither a newline nor a documentation comment, without
/// consuming anything.
fn peekPastNewlines(self: *Parser) Token {
    var at = self.index;
    while (at < self.tokens.len) : (at += 1) {
        switch (self.tokens[at].kind) {
            .newline, .doc_comment => {},
            else => return self.tokens[at],
        }
    }
    return self.tokens[self.tokens.len - 1];
}

fn skipToNextStatement(self: *Parser) void {
    while (true) {
        const token = self.peek();
        if (token.kind == .eof) return;
        _ = self.advance();
        if (token.kind == .newline) return;
    }
}

fn report(self: *Parser, span: Source.Span, message: []const u8, help: []const u8) Error {
    try self.diagnostics.append(self.arena, .{
        .message = message,
        .span = span,
        .help = help,
    });
    return error.ParseFailed;
}

fn reportFmt(
    self: *Parser,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error {
    const message = try std.fmt.allocPrint(self.arena, message_format, message_args);
    return self.report(span, message, help);
}

fn node(self: *Parser, span: Source.Span, data: Ast.Expression.Data) Error!*const Ast.Expression {
    const depth = 1 + deepestChild(data);
    if (depth > max_expression_depth) {
        return self.report(
            span,
            "this expression is too long",
            "Split it across several variables.",
        );
    }
    const result = try self.arena.create(Ast.Expression);
    result.* = .{ .span = span, .data = data, .depth = depth };
    return result;
}

fn deepestChild(data: Ast.Expression.Data) u32 {
    return switch (data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name => 0,
        .unary => |unary| unary.operand.depth,
        .binary => |binary| @max(binary.left.depth, binary.right.depth),
        .logical => |logical| @max(logical.left.depth, logical.right.depth),
        .comparison => |comparison| blk: {
            var deepest: u32 = 0;
            for (comparison.operands) |operand| deepest = @max(deepest, operand.depth);
            break :blk deepest;
        },
        .call => |call| blk: {
            var deepest = call.callee.depth;
            for (call.arguments) |argument| deepest = @max(deepest, argument.depth);
            break :blk deepest;
        },
    };
}

/// Opens one level of section 3.4 nesting at a delimiter, reporting at that
/// delimiter if it would cross the limit. Pair with `defer self.unnest()`.
fn nest(self: *Parser, delimiter: Source.Span) Error!void {
    if (self.nesting >= max_nesting) {
        return self.report(
            delimiter,
            "this is nested too deeply",
            "Emerald accepts 256 levels of nesting. Move part of it into a local variable or a function.",
        );
    }
    self.nesting += 1;
}

fn unnest(self: *Parser) void {
    self.nesting -= 1;
}

/// The same for recursion that opens no delimiter. Pair with
/// `defer self.unrecurse()`.
fn recurse(self: *Parser, at: Source.Span) Error!void {
    if (self.recursion >= max_expression_depth) {
        return self.report(
            at,
            "this is nested too deeply",
            "Split it into smaller pieces, such as local variables.",
        );
    }
    self.recursion += 1;
}

fn unrecurse(self: *Parser) void {
    self.recursion -= 1;
}

fn spanning(from: Source.Span, to: Source.Span) Source.Span {
    return .{ .start = from.start, .end = to.end };
}

// Statements.

fn parseStatement(self: *Parser) Error!Ast.Statement {
    return switch (self.peek().kind) {
        .keyword_var => self.parseDeclaration(true),
        .keyword_const => self.parseDeclaration(false),
        .keyword_if => self.parseIf(),
        .keyword_func => blk: {
            const nested = !self.at_top_level;
            const keyword = self.peek().span;
            // Parsed in full even when it will be rejected, so recovery
            // resumes after its closing brace instead of reporting that brace
            // as a second, unrelated error.
            const statement = try self.parseFunctionDeclaration();
            if (nested) {
                return self.report(
                    keyword,
                    "nested functions are not available yet",
                    "Move this function to the top level.",
                );
            }
            break :blk statement;
        },
        .keyword_return => self.parseReturn(),
        else => self.parseSimpleStatement(),
    };
}

/// Section 7.1's shape: `func name(params): ReturnType { body }`. Parameter
/// defaults and nested declarations are deferred; every parameter needs an
/// explicit type, which section 7.2 calls the normal case for named functions.
fn parseFunctionDeclaration(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();

    const name = self.peek();
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a name after `func`, found {s}",
            .{name.kind.describe()},
            "A function declaration needs a name, as in `func greet() { }`.",
        );
    }
    _ = self.advance();

    const opening = self.peek();
    if (opening.kind != .left_paren) {
        return self.reportFmt(
            opening.span,
            "expected `(` after `{s}`, found {s}",
            .{ self.text(name), opening.kind.describe() },
            "Every function declares its parameters in parentheses, even when there are none.",
        );
    }
    _ = self.advance();

    var parameters: std.ArrayList(Ast.Parameter) = .empty;
    if (!self.check(.right_paren)) {
        while (true) {
            try parameters.append(self.arena, try self.parseParameter());
            if (self.match(.comma) == null) break;
        }
    }

    const closing = self.peek();
    if (closing.kind != .right_paren) {
        return self.reportFmt(
            closing.span,
            "expected `)` to close this parameter list, found {s}",
            .{closing.kind.describe()},
            "Add the closing parenthesis, or check for a missing comma between parameters.",
        );
    }
    _ = self.advance();

    var return_annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) return_annotation = try self.parseTypeExpression();

    const body = try self.parseBlock();

    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .function_declaration = .{
            .name = self.text(name),
            .name_span = name.span,
            .parameters = try parameters.toOwnedSlice(self.arena),
            .return_annotation = return_annotation,
            .body = body,
        } },
    };
}

fn parseParameter(self: *Parser) Error!Ast.Parameter {
    const name = self.peek();
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a parameter name, found {s}",
            .{name.kind.describe()},
            "A parameter is a name and a type, as in `count: Int`.",
        );
    }
    _ = self.advance();

    if (self.check(.equal)) {
        return self.report(
            self.peek().span,
            "default parameter values are not available yet",
            "Give this parameter a value at every call site for now.",
        );
    }

    if (self.match(.colon) == null) {
        return self.reportFmt(
            self.peek().span,
            "expected `:` and a type after `{s}`, found {s}",
            .{ self.text(name), self.peek().kind.describe() },
            "Every parameter needs an explicit type, as in `count: Int`.",
        );
    }

    const annotation = try self.parseTypeExpression();
    return .{ .name = self.text(name), .name_span = name.span, .annotation = annotation };
}

/// Section 7.1 allows a bare `return` for a function with no result. Whether a
/// value follows is decided by the same tokens that end an ordinary statement.
fn parseReturn(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();

    const next = self.peek();
    const value = switch (next.kind) {
        .newline, .eof, .right_brace => null,
        else => try self.parseExpression(),
    };

    try self.expectStatementEnd();
    return .{
        .span = if (value) |v| spanning(keyword.span, v.span) else keyword.span,
        .data = .{ .return_statement = .{ .keyword_span = keyword.span, .value = value } },
    };
}

/// Section 4.3: `var` permits rebinding, `const` does not. Both introduce one
/// binding at a time, which section 5.2 states directly.
fn parseDeclaration(self: *Parser, mutable: bool) Error!Ast.Statement {
    const keyword = self.advance();

    const name = self.peek();
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a name after `{s}`, found {s}",
            .{ if (mutable) "var" else "const", name.kind.describe() },
            "A declaration introduces one name, as in `var score = 0`.",
        );
    }
    _ = self.advance();

    var annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) annotation = try self.parseTypeExpression();

    // Section 4.1: an uninitialized variable is allowed only with an explicit
    // type, because there is nothing else to infer one from.
    if (annotation != null and !self.check(.equal)) {
        try self.expectStatementEnd();
        return .{
            .span = spanning(keyword.span, annotation.?.span),
            .data = .{ .declaration = .{
                .mutable = mutable,
                .name = self.text(name),
                .name_span = name.span,
                .annotation = annotation,
                .initializer = null,
            } },
        };
    }

    const equals = self.peek();
    if (equals.kind != .equal) {
        return self.reportFmt(
            equals.span,
            "expected `=` after `{s}`, found {s}",
            .{ self.text(name), equals.kind.describe() },
            "A declaration needs a value, as in `var score = 0`, or a type, as in `var score: Int`.",
        );
    }
    _ = self.advance();

    const initializer = try self.parseExpression();
    try self.expectStatementEnd();

    return .{
        .span = spanning(keyword.span, initializer.span),
        .data = .{ .declaration = .{
            .mutable = mutable,
            .name = self.text(name),
            .name_span = name.span,
            .annotation = annotation,
            .initializer = initializer,
        } },
    };
}

/// Parses a type.
///
/// Section 4.2 records the rule that matters here. Because section 3.3 lets a
/// name end in `?`, the lexer applies maximal munch and hands over `Int?` as a
/// single identifier token. In type position the parser splits that trailing `?`
/// back off, adjusting the span by its final byte. The split is safe because
/// optionality is only ever written in a type, never at a use site.
fn parseTypeExpression(self: *Parser) Error!Ast.TypeExpression {
    const token = self.peek();
    if (token.kind != .identifier) {
        return self.reportFmt(
            token.span,
            "expected a type, found {s}",
            .{token.kind.describe()},
            "Write a type name such as `Int`, `Float`, or `Bool`.",
        );
    }
    _ = self.advance();

    var written = self.text(token);
    var span = token.span;
    var question: ?Source.Span = null;

    if (std.mem.endsWith(u8, written, "?")) {
        question = .{ .start = span.end - 1, .end = span.end };
        written = written[0 .. written.len - 1];
        span = .{ .start = span.start, .end = span.end - 1 };
    } else if (self.check(.question)) {
        // A `?` that could not attach to a name, as in `[String]?`.
        question = self.advance().span;
    }

    return .{ .span = span, .name = written, .question_span = question };
}

fn parseIf(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const condition = try self.parseExpression();
    const then_block = try self.parseBlock();

    var otherwise: ?Ast.Else = null;
    var end = then_block.span;

    // Section 3.4's brace style puts `else` on its own line, so a newline always
    // separates it from the `}` above. That newline is a statement terminator
    // everywhere else, so it is only stepped over once an `else` is known to
    // follow; otherwise the `if` ends here and the newline still terminates it.
    if (self.peekPastNewlines().kind == .keyword_else) {
        self.skipSeparators();
        _ = self.advance();
        if (self.check(.keyword_if)) {
            try self.recurse(self.peek().span);
            defer self.unrecurse();
            const chained = try self.arena.create(Ast.Statement);
            chained.* = try self.parseIf();
            otherwise = .{ .chained = chained };
            end = chained.span;
        } else {
            const block = try self.parseBlock();
            otherwise = .{ .block = block };
            end = block.span;
        }
    }

    return .{
        .span = spanning(keyword.span, end),
        .data = .{ .conditional = .{
            .condition = condition,
            .then_block = then_block,
            .otherwise = otherwise,
        } },
    };
}

/// Section 3.4: braces delimit blocks, and a block is only ever part of a
/// declared construct. There is no standalone anonymous block.
fn parseBlock(self: *Parser) Error!Ast.Block {
    const opening = self.peek();
    if (opening.kind != .left_brace) {
        return self.reportFmt(
            opening.span,
            "expected `{{` to open a block, found {s}",
            .{opening.kind.describe()},
            "A body is written in braces, opening on the same line as the line that introduces it.",
        );
    }
    try self.nest(opening.span);
    defer self.unnest();
    _ = self.advance();

    // Every block, not only a function body: nested function declarations are
    // deferred, and one inside a top-level `if` is just as nested.
    const saved_top_level = self.at_top_level;
    self.at_top_level = false;
    defer self.at_top_level = saved_top_level;

    var statements: std.ArrayList(Ast.Statement) = .empty;
    while (true) {
        self.skipSeparators();
        if (self.check(.right_brace) or self.check(.eof)) break;

        if (self.parseStatement()) |statement| {
            try statements.append(self.arena, statement);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => self.skipToNextStatement(),
        }
    }

    const closing = self.peek();
    if (closing.kind != .right_brace) {
        return self.report(
            opening.span,
            "this block is never closed",
            "Add the closing `}` that ends it.",
        );
    }
    _ = self.advance();

    return .{
        .span = spanning(opening.span, closing.span),
        .statements = try statements.toOwnedSlice(self.arena),
    };
}

/// An assignment or an expression statement. The two are told apart by what
/// follows the first expression, because section 5.2 makes assignment a
/// statement rather than an expression.
fn parseSimpleStatement(self: *Parser) Error!Ast.Statement {
    const start = self.peek();
    const expression = try self.parseExpression();

    if (assignmentOperator(self.peek().kind)) |assignment| {
        _ = self.advance();
        if (expression.data != .name) {
            return self.report(
                expression.span,
                "this cannot be assigned to",
                "Only a name can be assigned to, as in `score = 1`.",
            );
        }

        const value = try self.parseExpression();

        // Section 5.2 rejects chained assignment outright.
        if (assignmentOperator(self.peek().kind) != null) {
            return self.report(
                self.peek().span,
                "assignments cannot be chained",
                "Write each assignment on its own line.",
            );
        }
        try self.expectStatementEnd();

        return .{
            .span = spanning(start.span, value.span),
            .data = .{ .assignment = .{
                .name = expression.data.name,
                .name_span = expression.span,
                .operation = assignment.operation,
                .value = value,
            } },
        };
    }

    return self.finishExpressionStatement(expression);
}

/// A plain `=` carries no operation; a compound form carries the operation it
/// lowers through. Section 5.3 lists the compound forms, and `**=` is not one.
const AssignmentForm = struct { operation: ?Ast.BinaryOperator };

fn assignmentOperator(kind: Token.Kind) ?AssignmentForm {
    return switch (kind) {
        .equal => .{ .operation = null },
        .plus_equal => .{ .operation = .add },
        .minus_equal => .{ .operation = .subtract },
        .star_equal => .{ .operation = .multiply },
        .slash_equal => .{ .operation = .divide },
        .slash_slash_equal => .{ .operation = .floor_divide },
        else => null,
    };
}

fn finishExpressionStatement(self: *Parser, expression: *const Ast.Expression) Error!Ast.Statement {
    // Section 5.2: a call may discard its result, but a pure expression whose
    // result is unused is a mistake, and the diagnostic should suggest the
    // update the writer probably meant.
    if (expression.data != .call) {
        return self.report(
            expression.span,
            "this result is never used",
            "Assign it to a name, or call a function that does something with it. `score + 1` on its own is usually meant to be `score += 1`.",
        );
    }

    try self.expectStatementEnd();
    return .{ .span = expression.span, .data = .{ .expression = expression } };
}

/// A statement ends at a newline, at the end of the file, or just before the
/// `}` that closes the block it sits in.
fn expectStatementEnd(self: *Parser) Error!void {
    const terminator = self.peek();
    switch (terminator.kind) {
        .newline => _ = self.advance(),
        .eof, .right_brace => {},
        else => return self.reportFmt(
            terminator.span,
            "expected the end of the line, found {s}",
            .{terminator.kind.describe()},
            "Statements end at a new line. Check for a missing operator or closing bracket.",
        ),
    }
}

// Expressions, loosest binding first.

fn parseExpression(self: *Parser) Error!*const Ast.Expression {
    return self.parseDisjunction();
}

fn parseDisjunction(self: *Parser) Error!*const Ast.Expression {
    var left = try self.parseConjunction();
    while (self.check(.keyword_or)) {
        _ = self.advance();
        const right = try self.parseConjunction();
        left = try self.node(spanning(left.span, right.span), .{ .logical = .{
            .operator = .disjunction,
            .left = left,
            .right = right,
        } });
    }
    return left;
}

fn parseConjunction(self: *Parser) Error!*const Ast.Expression {
    var left = try self.parseNegation();
    while (self.check(.keyword_and)) {
        _ = self.advance();
        const right = try self.parseNegation();
        left = try self.node(spanning(left.span, right.span), .{ .logical = .{
            .operator = .conjunction,
            .left = left,
            .right = right,
        } });
    }
    return left;
}

fn parseNegation(self: *Parser) Error!*const Ast.Expression {
    if (self.match(.keyword_not)) |token| {
        try self.recurse(token.span);
        defer self.unrecurse();
        const operand = try self.parseNegation();
        return self.node(spanning(token.span, operand.span), .{ .unary = .{
            .operator = .not,
            .operand = operand,
        } });
    }
    return self.parseComparison();
}

/// A whole comparison chain becomes one node, so `0 <= score <= 100` can
/// evaluate `score` once and short-circuit, as section 5.2 requires.
fn parseComparison(self: *Parser) Error!*const Ast.Expression {
    const first = try self.parseAdditive();
    if (comparisonOperator(self.peek().kind) == null) return first;

    var operands: std.ArrayList(*const Ast.Expression) = .empty;
    var operators: std.ArrayList(Ast.ComparisonOperator) = .empty;
    try operands.append(self.arena, first);

    var end = first.span;
    while (comparisonOperator(self.peek().kind)) |operator| {
        _ = self.advance();
        const operand = try self.parseAdditive();
        try operators.append(self.arena, operator);
        try operands.append(self.arena, operand);
        end = operand.span;
    }

    return self.node(spanning(first.span, end), .{ .comparison = .{
        .operands = try operands.toOwnedSlice(self.arena),
        .operators = try operators.toOwnedSlice(self.arena),
    } });
}

fn comparisonOperator(kind: Token.Kind) ?Ast.ComparisonOperator {
    return switch (kind) {
        .equal_equal => .equal,
        .bang_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        else => null,
    };
}

fn parseAdditive(self: *Parser) Error!*const Ast.Expression {
    var left = try self.parseMultiplicative();
    while (true) {
        const operator: Ast.BinaryOperator = switch (self.peek().kind) {
            .plus => .add,
            .minus => .subtract,
            else => return left,
        };
        _ = self.advance();
        const right = try self.parseMultiplicative();
        left = try self.node(spanning(left.span, right.span), .{ .binary = .{
            .operator = operator,
            .left = left,
            .right = right,
        } });
    }
}

fn parseMultiplicative(self: *Parser) Error!*const Ast.Expression {
    var left = try self.parseUnary();
    while (true) {
        const operator: Ast.BinaryOperator = switch (self.peek().kind) {
            .star => .multiply,
            .slash => .divide,
            .slash_slash => .floor_divide,
            .percent => .remainder,
            else => return left,
        };
        _ = self.advance();
        const right = try self.parseUnary();
        left = try self.node(spanning(left.span, right.span), .{ .binary = .{
            .operator = operator,
            .left = left,
            .right = right,
        } });
    }
}

fn parseUnary(self: *Parser) Error!*const Ast.Expression {
    if (self.match(.minus)) |token| {
        if (self.matchMinimumIntMagnitude()) |literal| {
            return self.node(spanning(token.span, literal.span), .{ .int_literal = std.math.minInt(i64) });
        }
        try self.recurse(token.span);
        defer self.unrecurse();
        const operand = try self.parseUnary();
        return self.node(spanning(token.span, operand.span), .{ .unary = .{
            .operator = .negate,
            .operand = operand,
        } });
    }
    return self.parsePower();
}

/// The right operand is a unary expression, not another power. That single
/// choice gives `**` its right associativity and lets `2 ** -3` parse, while
/// leaving `-2 ** 2` to mean `-(2 ** 2)` because unary minus sits above this.
fn parsePower(self: *Parser) Error!*const Ast.Expression {
    const left = try self.parsePostfix();
    if (!self.check(.star_star)) return left;
    const operator = self.advance();
    try self.recurse(operator.span);
    defer self.unrecurse();
    const right = try self.parseUnary();
    return self.node(spanning(left.span, right.span), .{ .binary = .{
        .operator = .power,
        .left = left,
        .right = right,
    } });
}

fn parsePostfix(self: *Parser) Error!*const Ast.Expression {
    var callee = try self.parsePrimary();
    while (self.check(.left_paren)) {
        try self.nest(self.peek().span);
        defer self.unnest();
        _ = self.advance();

        var arguments: std.ArrayList(*const Ast.Expression) = .empty;
        if (!self.check(.right_paren)) {
            while (true) {
                try arguments.append(self.arena, try self.parseExpression());
                if (self.match(.comma) == null) break;
            }
        }

        const closing = self.peek();
        if (closing.kind != .right_paren) {
            return self.reportFmt(
                closing.span,
                "expected `)` to close this call, found {s}",
                .{closing.kind.describe()},
                "Add the closing parenthesis, or check for a missing comma between arguments.",
            );
        }
        _ = self.advance();

        callee = try self.node(spanning(callee.span, closing.span), .{ .call = .{
            .callee = callee,
            .arguments = try arguments.toOwnedSlice(self.arena),
        } });
    }
    return callee;
}

fn parsePrimary(self: *Parser) Error!*const Ast.Expression {
    const token = self.peek();
    switch (token.kind) {
        .int_literal => {
            _ = self.advance();
            return self.node(token.span, .{ .int_literal = try self.parseIntLiteral(token) });
        },
        .float_literal => {
            _ = self.advance();
            return self.node(token.span, .{ .float_literal = try self.parseFloatLiteral(token) });
        },
        .identifier => {
            _ = self.advance();
            return self.node(token.span, .{ .name = self.text(token) });
        },
        .keyword_true, .keyword_false => {
            _ = self.advance();
            return self.node(token.span, .{ .bool_literal = token.kind == .keyword_true });
        },
        .keyword_nothing => {
            _ = self.advance();
            return self.node(token.span, .{ .nothing_literal = {} });
        },
        .left_paren => {
            try self.nest(token.span);
            defer self.unnest();
            _ = self.advance();
            const inner = try self.parseExpression();
            const closing = self.peek();
            if (closing.kind != .right_paren) {
                return self.reportFmt(
                    closing.span,
                    "expected `)` to close this group, found {s}",
                    .{closing.kind.describe()},
                    "Add the closing parenthesis.",
                );
            }
            _ = self.advance();
            return inner;
        },
        else => return self.reportFmt(
            token.span,
            "expected an expression, found {s}",
            .{token.kind.describe()},
            "An expression is a number, a name, or something built from them.",
        ),
    }
}

/// The minimum `Int` is written `-9223372036854775808`, but its digits alone
/// are one past the maximum, because the range is asymmetric. A literal is
/// read before the minus is applied to it, so the pair is taken together here.
///
/// Only when the minus applies to the literal alone. In `-9223372036854775808
/// ** 2` it applies to the power, which binds tighter, so the literal stands
/// by itself and is out of range, as it would be anywhere else. Calling the
/// literal is excluded for the same reason, although it is an error anyway.
fn matchMinimumIntMagnitude(self: *Parser) ?Token {
    const literal = self.peek();
    if (literal.kind != .int_literal) return null;

    var buffer: [32]u8 = undefined;
    const digits = self.stripSeparators(self.text(literal), &buffer) orelse return null;
    const magnitude = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (magnitude != @as(u64, std.math.maxInt(i64)) + 1) return null;

    switch (self.peekAfterNext().kind) {
        .star_star, .left_paren => return null,
        else => return self.advance(),
    }
}

/// Underscores separate digits and carry no value, so they are removed before
/// the digits are read. The lexer has already rejected every malformed form.
fn parseIntLiteral(self: *Parser, token: Token) Error!i64 {
    var buffer: [32]u8 = undefined;
    const digits = self.stripSeparators(self.text(token), &buffer) orelse
        return self.tooLarge(token, "Int");

    return std.fmt.parseInt(i64, digits, 10) catch
        return self.tooLarge(token, "Int");
}

fn parseFloatLiteral(self: *Parser, token: Token) Error!f64 {
    var buffer: [512]u8 = undefined;
    const digits = self.stripSeparators(self.text(token), &buffer) orelse
        return self.tooLarge(token, "Float");

    return std.fmt.parseFloat(f64, digits) catch
        return self.tooLarge(token, "Float");
}

fn stripSeparators(_: Parser, literal: []const u8, buffer: []u8) ?[]const u8 {
    if (literal.len > buffer.len) return null;
    var length: usize = 0;
    for (literal) |byte| {
        if (byte == '_') continue;
        buffer[length] = byte;
        length += 1;
    }
    return buffer[0..length];
}

fn tooLarge(self: *Parser, token: Token, comptime type_name: []const u8) Error {
    return self.report(
        token.span,
        "this number is outside the range of " ++ type_name,
        if (std.mem.eql(u8, type_name, "Int"))
            "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807."
        else
            "`Float` holds IEEE-754 binary64 values.",
    );
}
