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
    const result = try self.arena.create(Ast.Expression);
    result.* = .{ .span = span, .data = data };
    return result;
}

fn spanning(from: Source.Span, to: Source.Span) Source.Span {
    return .{ .start = from.start, .end = to.end };
}

// Statements.

fn parseStatement(self: *Parser) Error!Ast.Statement {
    const expression = try self.parseExpression();

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

    const terminator = self.peek();
    if (terminator.kind != .newline and terminator.kind != .eof) {
        return self.reportFmt(
            terminator.span,
            "expected the end of the line, found {s}",
            .{terminator.kind.describe()},
            "Statements end at a new line. Check for a missing operator or closing bracket.",
        );
    }
    _ = self.match(.newline);

    return .{ .span = expression.span, .data = .{ .expression = expression } };
}

// Expressions, loosest binding first.

fn parseExpression(self: *Parser) Error!*const Ast.Expression {
    return self.parseAdditive();
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
    _ = self.advance();
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
        .left_paren => {
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
