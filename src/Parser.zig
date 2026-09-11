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
const unicode = @import("unicode.zig");

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

/// A name as every later stage sees it: section 3.3 makes canonically
/// equivalent spellings the same name, so a name not already in NFC is
/// normalized here, once, where every name passes through.
fn identifier(self: *Parser, token: Token) Error![]const u8 {
    const written = self.text(token);
    if (unicode.quickCheck(written) == .yes) return written;
    return unicode.normalize(self.arena, written);
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

/// Recovery after a failed statement: skip to the start of the next one.
///
/// Usually that is the next line. When the failed line opened a block, as a
/// broken loop or `if` header does, the whole block goes with it; otherwise its
/// closing brace would surface later as a second, unrelated error. A `}` that
/// closes an enclosing block is left for that block to consume.
fn skipToNextStatement(self: *Parser) void {
    // A stray `}` at the top level is itself the failed statement.
    if (self.check(.right_brace)) {
        _ = self.advance();
        return;
    }

    var depth: usize = 0;
    while (true) {
        switch (self.peek().kind) {
            .eof => return,
            .newline => if (depth == 0) {
                _ = self.advance();
                return;
            },
            .left_brace => depth += 1,
            .right_brace => {
                if (depth == 0) return;
                depth -= 1;
                if (depth == 0) {
                    _ = self.advance();
                    return;
                }
            },
            else => {},
        }
        _ = self.advance();
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
        .range => |range| @max(range.start.depth, range.end.depth),
        .list_literal => |elements| blk: {
            var deepest: u32 = 0;
            for (elements) |element| deepest = @max(deepest, element.depth);
            break :blk deepest;
        },
        .string_literal => 0,
        .interpolation => |parts| blk: {
            var deepest: u32 = 0;
            for (parts) |part| switch (part) {
                .text => {},
                .expression => |expression| deepest = @max(deepest, expression.depth),
            };
            break :blk deepest;
        },
        .index => |index| @max(index.base.depth, index.index.depth),
        .member => |member| member.base.depth,
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
        .keyword_while => self.parseWhile(),
        .keyword_for => self.parseFor(),
        .keyword_break => self.parseLoopExit(.break_statement),
        .keyword_continue => self.parseLoopExit(.continue_statement),
        // Only reachable at the top level: a block stops at its own `}`.
        .right_brace => self.report(
            self.peek().span,
            "this `}` does not close anything",
            "Remove it, or look above for a block that is missing its opening `{`.",
        ),
        else => self.parseSimpleStatement(),
    };
}

/// Section 6.4: `while condition { body }`.
fn parseWhile(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const condition = try self.parseExpression();
    const body = try self.parseBlock();
    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .while_loop = .{ .condition = condition, .body = body } },
    };
}

/// Section 6.4: `for name in iterable { body }`.
fn parseFor(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();

    // `_` visits each value without naming it.
    const name = self.peek();
    if (name.kind != .identifier and name.kind != .underscore) {
        return self.reportFmt(
            name.span,
            "expected a name after `for`, found {s}",
            .{name.kind.describe()},
            "A `for` loop names each value it visits, as in `for number in 1..5`.",
        );
    }
    _ = self.advance();

    if (self.match(.keyword_in) == null) {
        return self.reportFmt(
            self.peek().span,
            "expected `in` after `{s}`, found {s}",
            .{ self.text(name), self.peek().kind.describe() },
            "Write what to loop over after `in`, as in `for number in 1..5`.",
        );
    }

    const iterable = try self.parseExpression();
    const body = try self.parseBlock();
    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .for_loop = .{
            .name = try self.identifier(name),
            .name_span = name.span,
            .iterable = iterable,
            .body = body,
        } },
    };
}

/// `break` or `continue`. Whether one is inside a loop is the checker's
/// question, as whether a `return` is inside a function is.
fn parseLoopExit(self: *Parser, comptime kind: std.meta.Tag(Ast.Statement.Data)) Error!Ast.Statement {
    const keyword = self.advance();
    const data = @unionInit(Ast.Statement.Data, @tagName(kind), keyword.span);
    return self.finishSimpleStatement(.{ .span = keyword.span, .data = data });
}

/// Ends a statement that may carry section 6.2's trailing `if`, which guards
/// exactly one simple statement: `return if not valid?()` or
/// `print("Bonus") if score > 100`. It becomes an ordinary `if` with no `else`
/// whose block holds that statement, so no later pass needs to know about it.
fn finishSimpleStatement(self: *Parser, statement: Ast.Statement) Error!Ast.Statement {
    if (self.match(.keyword_if) == null) {
        try self.expectStatementEnd();
        return statement;
    }

    const condition = try self.parseExpression();
    try self.expectStatementEnd();

    const guarded = try self.arena.alloc(Ast.Statement, 1);
    guarded[0] = statement;
    return .{
        .span = spanning(statement.span, condition.span),
        .data = .{ .conditional = .{
            .condition = condition,
            .then_block = .{ .span = statement.span, .statements = guarded },
            .otherwise = null,
            .trailing = true,
        } },
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
            .name = try self.identifier(name),
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
    return .{ .name = try self.identifier(name), .name_span = name.span, .annotation = annotation };
}

/// Section 7.1 allows a bare `return` for a function with no result. Whether a
/// value follows is decided by the same tokens that end an ordinary statement.
fn parseReturn(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();

    // `return if not ready` is a bare return guarded by a trailing `if`.
    const next = self.peek();
    const value = switch (next.kind) {
        .newline, .eof, .right_brace, .keyword_if => null,
        else => try self.parseExpression(),
    };

    return self.finishSimpleStatement(.{
        .span = if (value) |v| spanning(keyword.span, v.span) else keyword.span,
        .data = .{ .return_statement = .{ .keyword_span = keyword.span, .value = value } },
    });
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
        try self.rejectGuardedDeclaration(name);
        try self.expectStatementEnd();
        return .{
            .span = spanning(keyword.span, annotation.?.span),
            .data = .{ .declaration = .{
                .mutable = mutable,
                .name = try self.identifier(name),
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
    try self.rejectGuardedDeclaration(name);
    try self.expectStatementEnd();

    return .{
        .span = spanning(keyword.span, initializer.span),
        .data = .{ .declaration = .{
            .mutable = mutable,
            .name = try self.identifier(name),
            .name_span = name.span,
            .annotation = annotation,
            .initializer = initializer,
        } },
    };
}

/// A trailing `if` would put the declaration inside a block of its own, where
/// section 6.1 would end its scope on the same line, so it could never be used.
fn rejectGuardedDeclaration(self: *Parser, name: Token) Error!void {
    const keyword = self.peek();
    if (keyword.kind != .keyword_if) return;
    const help = try std.fmt.allocPrint(
        self.arena,
        "Declare `{s}` on its own line first, then assign it with the trailing `if`, as in `{s} = value if condition`.",
        .{ self.text(name), self.text(name) },
    );
    return self.report(keyword.span, "a declaration cannot have a trailing `if`", help);
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
    if (token.kind == .left_bracket) return self.parseListType();
    if (token.kind != .identifier) {
        return self.reportFmt(
            token.span,
            "expected a type, found {s}",
            .{token.kind.describe()},
            "Write a type name such as `Int`, `Float`, or `Bool`.",
        );
    }
    _ = self.advance();

    var written = try self.identifier(token);
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

/// Section 8.2's `[T]`, and `[T]?` for an optional list.
fn parseListType(self: *Parser) Error!Ast.TypeExpression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    const element = try self.arena.create(Ast.TypeExpression);
    element.* = try self.parseTypeExpression();

    if (self.check(.colon)) {
        return self.report(
            self.peek().span,
            "dictionary types are not available yet",
            "Only list types, such as `[Int]`, can be written so far.",
        );
    }
    const closing = self.peek();
    if (closing.kind != .right_bracket) {
        return self.reportFmt(
            closing.span,
            "expected `]` to close this list type, found {s}",
            .{closing.kind.describe()},
            "A list type is an element type in brackets, as in `[Int]`.",
        );
    }
    _ = self.advance();

    const question: ?Source.Span = if (self.match(.question)) |token| token.span else null;
    return .{
        .span = spanning(opening.span, closing.span),
        .name = "",
        .element = element,
        .question_span = question,
    };
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
        const target = try self.assignmentTarget(expression);

        const value = try self.parseExpression();

        // Section 5.2 rejects chained assignment outright.
        if (assignmentOperator(self.peek().kind) != null) {
            return self.report(
                self.peek().span,
                "assignments cannot be chained",
                "Write each assignment on its own line.",
            );
        }

        return self.finishSimpleStatement(.{
            .span = spanning(start.span, value.span),
            .data = .{ .assignment = .{
                .name = target.name,
                .name_span = target.name_span,
                .indices = target.indices,
                .target_span = expression.span,
                .operation = assignment.operation,
                .value = value,
            } },
        });
    }

    return self.finishExpressionStatement(expression);
}

const Target = struct {
    name: []const u8,
    name_span: Source.Span,
    indices: []const *const Ast.Expression,
};

/// What can be assigned to: a name, or an element of a list reached from a
/// name through indexing, as in `grid[0][1] = 5`.
fn assignmentTarget(self: *Parser, expression: *const Ast.Expression) Error!Target {
    var indices: std.ArrayList(*const Ast.Expression) = .empty;
    var current = expression;
    while (current.data == .index) {
        try indices.append(self.arena, current.data.index.index);
        current = current.data.index.base;
    }
    if (current.data != .name) {
        return self.report(
            expression.span,
            "this cannot be assigned to",
            "Assign to a name, as in `score = 1`, or to an element of a list, as in `scores[0] = 1`.",
        );
    }
    // Collected innermost first; stored outermost first, the order they apply.
    std.mem.reverse(*const Ast.Expression, indices.items);
    return .{
        .name = current.data.name,
        .name_span = current.span,
        .indices = try indices.toOwnedSlice(self.arena),
    };
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

    return self.finishSimpleStatement(.{ .span = expression.span, .data = .{ .expression = expression } });
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
    const first = try self.parseRange();
    if (comparisonOperator(self.peek().kind) == null) return first;

    var operands: std.ArrayList(*const Ast.Expression) = .empty;
    var operators: std.ArrayList(Ast.ComparisonOperator) = .empty;
    try operands.append(self.arena, first);

    var end = first.span;
    while (comparisonOperator(self.peek().kind)) |operator| {
        _ = self.advance();
        const operand = try self.parseRange();
        try operators.append(self.arena, operator);
        try operands.append(self.arena, operand);
        end = operand.span;
    }

    return self.node(spanning(first.span, end), .{ .comparison = .{
        .operands = try operands.toOwnedSlice(self.arena),
        .operators = try operators.toOwnedSlice(self.arena),
    } });
}

/// Section 6.4's `start..end` and `start..<end`. Looser than arithmetic, so
/// `0..count - 1` ends at `count - 1`, and tighter than comparison. A range has
/// exactly one start and one end, so `1..2..3` is rejected rather than read
/// either way.
fn parseRange(self: *Parser) Error!*const Ast.Expression {
    const start = try self.parseAdditive();
    const inclusive = switch (self.peek().kind) {
        .dot_dot => true,
        .dot_dot_less => false,
        else => return start,
    };
    _ = self.advance();
    const end = try self.parseAdditive();

    switch (self.peek().kind) {
        .dot_dot, .dot_dot_less => return self.report(
            self.peek().span,
            "a range has one start and one end",
            "Write a single range, as in `1..10`.",
        ),
        else => {},
    }

    return self.node(spanning(start.span, end.span), .{ .range = .{
        .start = start,
        .end = end,
        .inclusive = inclusive,
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

/// Calls, indexing, and member access, which all bind tighter than any
/// operator and chain left to right: `grid[0].count`, `list.contains?(3)`.
fn parsePostfix(self: *Parser) Error!*const Ast.Expression {
    var base = try self.parsePrimary();
    while (true) {
        base = switch (self.peek().kind) {
            .left_paren => try self.finishCall(base),
            .left_bracket => try self.finishIndex(base),
            .dot => try self.finishMember(base),
            .question_dot => return self.report(
                self.peek().span,
                "optional chaining is not available yet",
                "Optional values arrive with a later version of Emerald.",
            ),
            else => return base,
        };
    }
}

fn finishCall(self: *Parser, callee: *const Ast.Expression) Error!*const Ast.Expression {
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

    return self.node(spanning(callee.span, closing.span), .{ .call = .{
        .callee = callee,
        .arguments = try arguments.toOwnedSlice(self.arena),
    } });
}

fn finishIndex(self: *Parser, base: *const Ast.Expression) Error!*const Ast.Expression {
    try self.nest(self.peek().span);
    defer self.unnest();
    _ = self.advance();

    const index = try self.parseExpression();
    const closing = self.peek();
    if (closing.kind != .right_bracket) {
        return self.reportFmt(
            closing.span,
            "expected `]` to close this index, found {s}",
            .{closing.kind.describe()},
            "An index is one expression in brackets, as in `scores[0]`.",
        );
    }
    _ = self.advance();

    return self.node(spanning(base.span, closing.span), .{ .index = .{ .base = base, .index = index } });
}

/// Section 3.4 keeps keywords reserved after `.`, so only a name may follow.
fn finishMember(self: *Parser, base: *const Ast.Expression) Error!*const Ast.Expression {
    _ = self.advance();
    const name = self.peek();
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a property or method name after `.`, found {s}",
            .{name.kind.describe()},
            "Write the name of what to use, as in `scores.count`.",
        );
    }
    _ = self.advance();

    return self.node(spanning(base.span, name.span), .{ .member = .{
        .base = base,
        .name = try self.identifier(name),
        .name_span = name.span,
    } });
}

/// Section 8.2's list literal. A trailing comma is allowed, which keeps a
/// literal written one element per line uniform. Newlines inside the brackets
/// never end the statement, which the lexer already arranges.
fn parseListLiteral(self: *Parser) Error!*const Ast.Expression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    var elements: std.ArrayList(*const Ast.Expression) = .empty;
    while (!self.check(.right_bracket)) {
        try elements.append(self.arena, try self.parseExpression());
        if (self.check(.colon)) {
            return self.report(
                self.peek().span,
                "dictionaries are not available yet",
                "Only lists, such as `[1, 2, 3]`, can be written so far.",
            );
        }
        if (self.match(.comma) == null) break;
    }

    const closing = self.peek();
    if (closing.kind != .right_bracket) {
        return self.reportFmt(
            closing.span,
            "expected `]` to close this list, found {s}",
            .{closing.kind.describe()},
            "Separate the elements with commas and close the list with `]`.",
        );
    }
    _ = self.advance();

    return self.node(spanning(opening.span, closing.span), .{
        .list_literal = try elements.toOwnedSlice(self.arena),
    });
}

fn parsePrimary(self: *Parser) Error!*const Ast.Expression {
    const token = self.peek();
    switch (token.kind) {
        .left_bracket => return self.parseListLiteral(),
        .string_literal, .raw_string_literal, .multiline_string_literal => {
            _ = self.advance();
            return self.node(token.span, .{ .string_literal = try self.cookLiteral(token) });
        },
        .string_start => return self.parseInterpolation(),
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
            return self.node(token.span, .{ .name = try self.identifier(token) });
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

// Strings.

/// A string with no interpolation, finished.
fn cookLiteral(self: *Parser, token: Token) Error![]const u8 {
    const written = self.text(token);
    return switch (token.kind) {
        // Section 5.1: raw strings process nothing.
        .raw_string_literal => written[1 .. written.len - 1],
        .string_literal => unescape(self.arena, written[1 .. written.len - 1]),
        .multiline_string_literal => blk: {
            const segments = try self.cookSegments(&.{written[3 .. written.len - 3]}, true, token.span);
            break :blk segments[0];
        },
        else => unreachable,
    };
}

/// Section 5.1's interpolation: text and expressions in turn. The lexer has
/// already split the string at each `#{` and its closing `}`.
fn parseInterpolation(self: *Parser) Error!*const Ast.Expression {
    const start = self.advance();
    const opening = self.text(start);
    const multiline = std.mem.startsWith(u8, opening, "\"\"\"");

    var raws: std.ArrayList([]const u8) = .empty;
    var expressions: std.ArrayList(*const Ast.Expression) = .empty;
    try raws.append(self.arena, opening[(if (multiline) 3 else 1) .. opening.len - 2]);

    const end = while (true) {
        const next = self.peek();
        if (next.kind == .string_middle or next.kind == .string_end) {
            return self.report(
                next.span,
                "an interpolation needs an expression",
                "Put a value between the braces, as in `#{name}`, or write `\\#{` for the characters themselves.",
            );
        }
        try self.nest(next.span);
        const expression = try self.parseExpression();
        self.unnest();
        try expressions.append(self.arena, expression);

        const part = self.peek();
        const part_text = self.text(part);
        switch (part.kind) {
            .string_middle => {
                _ = self.advance();
                try raws.append(self.arena, part_text[1 .. part_text.len - 2]);
            },
            .string_end => {
                _ = self.advance();
                try raws.append(self.arena, part_text[1 .. part_text.len - @as(usize, if (multiline) 3 else 1)]);
                break part;
            },
            else => return self.reportFmt(
                part.span,
                "expected `}}` to end this interpolation, found {s}",
                .{part.kind.describe()},
                "An interpolation holds one expression, as in `#{count}`.",
            ),
        }
    };

    const texts = try self.cookSegments(raws.items, multiline, start.span);
    var parts: std.ArrayList(Ast.Expression.Part) = .empty;
    for (texts, 0..) |text_part, position| {
        if (text_part.len > 0) try parts.append(self.arena, .{ .text = text_part });
        if (position < expressions.items.len) try parts.append(self.arena, .{ .expression = expressions.items[position] });
    }
    return self.node(spanning(start.span, end.span), .{ .interpolation = try parts.toOwnedSlice(self.arena) });
}

/// Finishes the text between a string's delimiters and interpolations: the
/// segments in order, which are slices of the source.
///
/// A triple-quoted string also gets section 5.1's layout. Its text starts on
/// the line after the opening `"""`, and that newline is not part of it. The
/// closing `"""` sits on a line of its own, and its indentation is removed
/// from every line; a line indented less is an error, except a blank one. The
/// newline before the closing line is not part of the text either. Escapes are
/// processed last, so `\n` written in the text is never mistaken for a line
/// break, and a Windows line ending becomes `\n` so the value does not depend
/// on how the file was saved.
fn cookSegments(self: *Parser, raws: []const []const u8, multiline: bool, opening: Source.Span) Error![][]const u8 {
    const cooked = try self.arena.alloc([]const u8, raws.len);
    if (!multiline) {
        for (raws, cooked) |raw, *text_part| text_part.* = try unescape(self.arena, raw);
        return cooked;
    }

    const opening_delimiter: Source.Span = .{ .start = opening.start, .end = opening.start + 3 };
    const contents = try self.arena.dupe([]const u8, raws);

    // The opening line holds nothing but the delimiter.
    const first = contents[0];
    if (std.mem.startsWith(u8, first, "\r\n")) {
        contents[0] = first[2..];
    } else if (std.mem.startsWith(u8, first, "\n")) {
        contents[0] = first[1..];
    } else {
        return self.report(
            opening_delimiter,
            "a triple-quoted string starts on the line after its `\"\"\"`",
            "Move the text to the next line, or use `\"...\"` for a single line.",
        );
    }

    // The closing line holds only indentation, which sets what is removed.
    const last = contents[contents.len - 1];
    const closing_line = if (std.mem.lastIndexOfScalar(u8, last, '\n')) |newline| newline + 1 else 0;
    const indentation = last[closing_line..];
    const on_own_line = (closing_line > 0 or contents.len == 1) and
        std.mem.indexOfNone(u8, indentation, " \t") == null;
    if (!on_own_line) {
        return self.report(
            opening_delimiter,
            "the closing `\"\"\"` of this string needs a line of its own",
            "Put the closing `\"\"\"` on its own line; its indentation is removed from every line of the text.",
        );
    }
    // Drop the newline before the closing line, and the line itself.
    contents[contents.len - 1] = std.mem.trimEnd(u8, last[0..if (closing_line > 0) closing_line - 1 else 0], "\r");

    var at_line_start = true;
    for (contents, cooked, 0..) |content, *text_part, segment| {
        var built: std.ArrayList(u8) = .empty;
        var position: usize = 0;
        while (position <= content.len) {
            if (at_line_start) {
                at_line_start = false;
                const rest = content[position..];
                const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                const line = std.mem.trimEnd(u8, rest[0..line_end], "\r");
                const ends_line = line_end < rest.len or segment == contents.len - 1;
                if (ends_line and std.mem.indexOfNone(u8, line, " \t") == null) {
                    position += line.len; // a blank line keeps no indentation
                } else if (std.mem.startsWith(u8, line, indentation)) {
                    position += indentation.len;
                } else {
                    // Underline the short indentation, through the first
                    // character of the line's text.
                    const offset = @intFromPtr(content.ptr) - @intFromPtr(self.source.text.ptr) + position;
                    const leading = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
                    return self.report(
                        .{ .start = @intCast(offset), .end = @intCast(offset + @min(leading + 1, line.len)) },
                        "this line is indented less than the closing `\"\"\"`",
                        "Indent every line of the text at least as far as the closing `\"\"\"`, which sets how much indentation is removed.",
                    );
                }
            }
            if (position == content.len) break;
            const c = content[position];
            position += 1;
            if (c == '\r' and position < content.len and content[position] == '\n') continue;
            try built.append(self.arena, c);
            if (c == '\n') at_line_start = true;
        }
        text_part.* = try unescape(self.arena, built.items);
    }
    return cooked;
}

/// Section 5.1's escapes. The lexer has already reported any it does not
/// recognize, so none reach here.
fn unescape(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var result: std.ArrayList(u8) = .empty;
    var position: usize = 0;
    while (position < raw.len) : (position += 1) {
        if (raw[position] != '\\' or position + 1 == raw.len) {
            try result.append(arena, raw[position]);
            continue;
        }
        position += 1;
        if (raw[position] == 'u') {
            // `\u{...}`, already validated by the lexer.
            const close = std.mem.indexOfScalarPos(u8, raw, position, '}').?;
            const code_point = std.fmt.parseInt(u21, raw[position + 2 .. close], 16) catch unreachable;
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
            try result.appendSlice(arena, buffer[0..length]);
            position = close;
            continue;
        }
        try result.append(arena, switch (raw[position]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => |c| c, // `\\`, `\"`, `\'`, and `\#` stand for themselves
        });
    }
    return result.toOwnedSlice(arena);
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
