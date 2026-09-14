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
/// Whether statements here are a file's own, which a struct declaration must
/// be. Set false for the duration of any block body.
at_top_level: bool = true,
/// Open parentheses and braces. Section 3.4 guarantees at least 256.
nesting: u32 = 0,
/// Whether the members being parsed are a class's rather than a struct's.
in_class: bool = false,
/// Whether they are a trait's (11.1).
in_trait: bool = false,
/// Whether the type being parsed adopts traits, which a struct's `@override`
/// needs (11.2).
has_traits: bool = false,
/// The type whose members are being parsed, and whether it names a base class
/// with `extends`, which is what gives `super` a meaning (10.7).
type_name: []const u8 = "",
has_base: bool = false,
/// Whether a section 12 enum's body is being parsed.
in_enum: bool = false,
/// Recursion that opens no delimiter: prefix `-` and `not`, the right side of
/// `**`, and `else if`. Bounded separately so that it cannot eat into the 256
/// delimiters section 3.4 promises, and so a very long chain of any of them is
/// still a diagnostic rather than a crash.
recursion: u32 = 0,
/// Whether the expression being parsed is the condition of an `if` or `while`,
/// or the iterable of a `for`. There, the next `{` opens the statement's body
/// rather than a trailing lambda, which is the rule section 7.4 states and the
/// reason it tells you to parenthesize the call: `if (items.any? { ... }) {`.
/// Any bracket or parenthesis clears it, because the body cannot begin inside
/// one.
in_control_header: bool = false,
/// Where `self` means something: directly inside a constructor or method body
/// (10.2). A lambda clears it, since a block that captured `self` could let the
/// value escape before every field is set, or outlive a method that changes it.
self_allowed: SelfContext = .nowhere,

/// `type_member` is section 10.4's type-level function or field, which belongs
/// to the type rather than to any value, so it has no `self` to offer.
/// Where `self` is being parsed. A class's methods share their object, so a
/// block or nested function inside one may use `self` (7.4), and
/// `class_member` stays in force inside both; a struct's `member` does not.
const SelfContext = enum { nowhere, member, class_member, member_lambda, member_nested, type_member };

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
    var using: std.ArrayList(Ast.Using) = .empty;
    while (true) {
        parser.skipSeparators();
        if (parser.peek().kind == .eof) break;

        // Section 14.2's `using` is a file-local declaration rather than a
        // statement, so it is collected here instead of among the statements.
        if (parser.check(.keyword_using)) {
            if (parser.parseUsing()) |declaration| {
                try using.append(arena, declaration);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => parser.skipToNextStatement(),
            }
            continue;
        }

        if (parser.parseStatement()) |statement| {
            try statements.append(arena, statement);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Resume at the next line so one mistake does not cascade, which is
            // what section 17.2 asks for.
            error.ParseFailed => parser.skipToNextStatement(),
        }
    }

    // Every allocation has to finish before the arena is copied into the
    // result, because copying it snapshots the list of blocks it owns.
    const owned_statements = try statements.toOwnedSlice(arena);
    const owned_using = try using.toOwnedSlice(arena);
    const owned_diagnostics = try parser.diagnostics.toOwnedSlice(arena);

    return .{
        .arena_state = arena_state,
        .program = .{ .statements = owned_statements, .using = owned_using },
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
    try self.note(span, message, help);
    return error.ParseFailed;
}

/// A mistake that leaves the syntax intact, so parsing carries on and nothing
/// after it is misread. Recovery from a failed statement skips to the next one,
/// which inside a nested block would report that block's `}` as a second error.
fn note(self: *Parser, span: Source.Span, message: []const u8, help: []const u8) std.mem.Allocator.Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = message,
        .span = span,
        .help = help,
    });
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
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .enum_value => 0,
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
        .tuple_literal => |positions| blk: {
            var deepest: u32 = 0;
            for (positions) |position| deepest = @max(deepest, position.depth);
            break :blk deepest;
        },
        .dictionary_literal => |entries| blk: {
            var deepest: u32 = 0;
            for (entries) |entry| {
                deepest = @max(deepest, @max(entry.key.depth, entry.value.depth));
            }
            break :blk deepest;
        },
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
        .type_test => |test_| test_.value.depth,
        // A block body's statements each carry their own bound, so only an
        // expression body extends this lambda's height.
        .case_expression => |case| blk: {
            var deepest: u32 = if (case.subject) |subject| subject.depth else 0;
            for (case.arms) |arm| {
                for (arm.alternatives) |alternative| deepest = @max(deepest, alternative.depth);
                if (arm.body == .value) deepest = @max(deepest, arm.body.value.depth);
            }
            if (case.otherwise) |otherwise| if (otherwise == .value) {
                deepest = @max(deepest, otherwise.value.depth);
            };
            break :blk deepest;
        },
        .lambda => |lambda| switch (lambda.body) {
            .expression => |expression| expression.depth,
            .block => 0,
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
            // Section 10.4's `func Vector2.origin()` written outside the type
            // it names. Parsed in full for recovery, then reported.
            if (self.startsTypeMember()) {
                const receiver = self.peekAfterNext();
                const parsed = try self.parseTypeFunction(null);
                return self.report(
                    parsed.member_span,
                    "a type-level function is declared inside its type",
                    try std.fmt.allocPrint(self.arena, "Move it inside the braces of `{s}`'s declaration.", .{self.text(receiver)}),
                );
            }
            // Section 7.1's nested function, which captures what is around it
            // as a block does, and so cannot use `self` any more than one can.
            const saved_self = self.self_allowed;
            if (nested and (self.self_allowed == .member or self.self_allowed == .member_lambda)) {
                self.self_allowed = .member_nested;
            }
            defer self.self_allowed = saved_self;
            break :blk try self.parseFunctionDeclaration();
        },
        .at => self.parseAnnotatedStatement(),
        .keyword_struct, .keyword_class, .keyword_trait, .keyword_enum => blk: {
            const nested = !self.at_top_level;
            const keyword = self.peek();
            const statement = try self.parseStructDeclaration();
            if (nested) {
                return self.reportFmt(
                    keyword.span,
                    "a {s} declaration belongs at the top level",
                    .{self.text(keyword)},
                    try std.fmt.allocPrint(self.arena, "Move this {s} out of the enclosing block.", .{self.text(keyword)}),
                );
            }
            break :blk statement;
        },
        // Section 8.2's `(left, right) = (right, left)`. Recognized before the
        // expression parser sees it, because `_` is a destination here and not
        // an expression anywhere.
        .left_paren => if (self.startsPatternAssignment())
            self.parseDestructuringAssignment()
        else
            self.parseSimpleStatement(),
        .keyword_using => self.report(
            self.peek().span,
            "a `using` declaration belongs at the top level of a file",
            "Move it out to the top level. `using` applies to the whole file wherever it is written.",
        ),
        .keyword_return => self.parseReturn(),
        .keyword_raise => self.parseRaise(),
        .keyword_try => self.parseTry(),
        .keyword_assert => self.parseAssert(),
        .keyword_case => blk: {
            const parsed = try self.parseCase();
            if (parsed.producesValue()) {
                return self.report(
                    spanning(parsed.keyword_span, self.tokens[self.index - 1].span),
                    "the value this `case` produces is never used",
                    "Assign it to a name, as in `const label = case ...`, or give each `when` a block in braces in place of `then`.",
                );
            }
            try self.expectStatementEnd();
            break :blk .{ .span = spanning(parsed.keyword_span, self.tokens[self.index - 1].span), .data = .{ .case_statement = parsed } };
        },
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

/// Section 16.1's annotations, collected from the lines in front of a
/// declaration. An unknown one is noted and skipped, so the declaration it was
/// written on is still read.
const Annotations = struct {
    override: ?Source.Span = null,
    abstract: ?Source.Span = null,
    test_annotation: ?Source.Span = null,
};

const known_annotations = [_][]const u8{ "override", "abstract", "test" };

fn parseAnnotations(self: *Parser) Error!Annotations {
    var found: Annotations = .{};
    while (self.check(.at)) {
        const at = self.advance();
        const name = self.peek();
        if (name.kind != .identifier) {
            return self.report(
                at.span,
                "expected an annotation name after `@`",
                "Write the annotation's name right after `@`, as in `@override`.",
            );
        }
        _ = self.advance();
        const span = spanning(at.span, name.span);
        const word = self.text(name);
        if (std.mem.eql(u8, word, "override") or std.mem.eql(u8, word, "abstract") or std.mem.eql(u8, word, "test")) {
            const slot = if (std.mem.eql(u8, word, "override")) &found.override else if (std.mem.eql(u8, word, "abstract")) &found.abstract else &found.test_annotation;
            if (slot.* != null) {
                try self.reportFmtNote(span, "`@{s}` is already written on this declaration", .{word}, "Write each annotation once.");
            }
            slot.* = span;
        } else if (closestAnnotation(word)) |suggestion| {
            try self.reportFmtNote(
                span,
                "`@{s}` is not an annotation",
                .{word},
                try std.fmt.allocPrint(self.arena, "Did you mean `@{s}`?", .{suggestion}),
            );
        } else {
            try self.reportFmtNote(
                span,
                "`@{s}` is not an annotation",
                .{word},
                "Emerald's annotations are `@override`, `@abstract`, and `@test`.",
            );
        }
        self.skipSeparators();
    }
    return found;
}

/// The known annotation a misspelling was probably meant to be: one at most
/// two edits away, ignoring case.
fn closestAnnotation(word: []const u8) ?[]const u8 {
    for (known_annotations) |known| {
        if (editDistance(word, known) <= 2) return known;
    }
    return null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return std.math.maxInt(usize);
    var previous: [33]usize = undefined;
    var current: [33]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |left, i| {
        current[0] = i + 1;
        for (b, 0..) |right, j| {
            const substitution = previous[j] + @intFromBool(std.ascii.toLower(left) != std.ascii.toLower(right));
            current[j + 1] = @min(substitution, @min(previous[j + 1], current[j]) + 1);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

fn reportFmtNote(
    self: *Parser,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error!void {
    try self.note(span, try std.fmt.allocPrint(self.arena, message_format, message_args), help);
}

/// A declaration written after annotations outside any type: a class, which
/// may be `@abstract`, or something no annotation applies to.
fn parseAnnotatedStatement(self: *Parser) Error!Ast.Statement {
    const annotations = try self.parseAnnotations();
    const next = self.peek();
    if (annotations.override) |span| {
        try self.note(
            span,
            "`@override` belongs on a method or property of a class",
            "Only a member of a class that extends another can replace one of its base class's members. Remove `@override` here.",
        );
    }
    if (next.kind == .keyword_class) {
        if (annotations.test_annotation) |span| try self.note(span, "`@test` belongs on a function", "Move `@test` to a top-level function with no parameters and no result.");
        var statement = try self.parseStatement();
        if (statement.data == .struct_declaration) statement.data.struct_declaration.abstract_span = annotations.abstract;
        return statement;
    }
    if (next.kind == .keyword_func and annotations.test_annotation != null) {
        var statement = try self.parseFunctionDeclaration();
        if (!self.at_top_level) {
            try self.note(annotations.test_annotation.?, "a test must be a top-level function", "Move this function out of the enclosing block, then keep `@test` on it.");
        } else statement.data.function_declaration.test_span = annotations.test_annotation;
        if (annotations.abstract) |span| try self.note(span, "a test function cannot be abstract", "Remove `@abstract`; a test needs a body to run.");
        return statement;
    }
    if (annotations.test_annotation) |span| try self.note(span, "`@test` belongs on a function", "Move `@test` to a top-level function with no parameters and no result.");
    if (annotations.abstract) |span| {
        if (next.kind == .keyword_trait) {
            try self.note(
                span,
                "a trait needs no `@abstract`",
                "A trait is never constructed, and a member written without a body is already a requirement. Remove `@abstract`.",
            );
        } else if (next.kind == .keyword_struct) {
            try self.note(
                span,
                "a struct cannot be abstract",
                "Only a class can be `@abstract`, since only a class can be extended. Remove `@abstract`, or declare a class.",
            );
        } else {
            try self.note(
                span,
                "`@abstract` belongs on a class or on one of its methods",
                "Remove `@abstract` here.",
            );
        }
    }
    if (next.kind == .eof or next.kind == .right_brace) {
        return self.report(
            next.span,
            "an annotation needs a declaration after it",
            "Write the class or method it belongs to on the next line.",
        );
    }
    return self.parseStatement();
}

/// Section 10.2's stored fields with their defaults, its one optional custom
/// constructor, its instance methods, and its computed properties. Without a
/// constructor, every field is one generated-constructor parameter, in
/// declaration order, which its default makes optional.
fn parseStructDeclaration(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const class = keyword.kind == .keyword_class;
    const trait = keyword.kind == .keyword_trait;
    const enumeration = keyword.kind == .keyword_enum;
    const word = self.text(keyword);
    const name = self.peek();
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a name after `{s}`, found {s}",
            .{ word, name.kind.describe() },
            try std.fmt.allocPrint(self.arena, "A {s} declaration needs a PascalCase name, as in `{s} Marker {{ }}`.", .{ word, word }),
        );
    }
    _ = self.advance();

    // Section 10.7's single inheritance. Section 11's traits come later.
    var base: ?Ast.TypeExpression = null;
    if (self.check(.keyword_extends)) {
        if (trait) {
            return self.report(
                self.peek().span,
                "a trait builds on other traits with `with`",
                "Write `with` in place of `extends`, as in `trait Pet with Named`. A trait cannot extend a class.",
            );
        }
        if (enumeration) {
            return self.report(
                self.peek().span,
                "an enum cannot extend another type",
                "An enum is a closed set of its own values. It can adopt traits with `with`.",
            );
        }
        if (!class) {
            return self.report(
                self.peek().span,
                "a struct cannot extend another type",
                "Structs do not inherit. Declare a class instead if this needs a base class.",
            );
        }
        _ = self.advance();
        const written = try self.parseTypeExpression();
        if (written.name.len == 0 or written.question_span != null) {
            try self.note(
                written.span,
                "a class can only extend another class",
                "Name the base class, as in `class Dog extends Animal`.",
            );
        } else {
            base = written;
        }
        if (self.check(.comma)) {
            return self.report(
                self.peek().span,
                "a class extends at most one class",
                "Emerald has single inheritance. Keep one base class.",
            );
        }
    }
    var traits: std.ArrayList(Ast.TypeExpression) = .empty;
    if (self.match(.keyword_with) != null) {
        while (true) {
            const written = try self.parseTypeExpression();
            if (written.name.len == 0 or written.question_span != null) {
                try self.note(
                    written.span,
                    "only a trait can follow `with`",
                    "Name the trait, as in `with Named`.",
                );
            } else {
                try traits.append(self.arena, written);
            }
            if (self.match(.comma) == null) break;
        }
    }

    if (self.match(.left_brace) == null) {
        return self.reportFmt(
            self.peek().span,
            "expected `{{` after `{s}`, found {s}",
            .{ self.text(name), self.peek().kind.describe() },
            try std.fmt.allocPrint(self.arena, "A {s} body is enclosed in braces, as in `{s} Marker {{ }}`.", .{ word, word }),
        );
    }
    const saved_class = self.in_class;
    const saved_trait = self.in_trait;
    const saved_type_name = self.type_name;
    const saved_has_base = self.has_base;
    const saved_has_traits = self.has_traits;
    const saved_enum = self.in_enum;
    self.in_enum = enumeration;
    self.in_class = class;
    self.in_trait = trait;
    self.has_traits = traits.items.len > 0;
    self.type_name = self.text(name);
    self.has_base = base != null;
    defer {
        self.in_class = saved_class;
        self.in_trait = saved_trait;
        self.type_name = saved_type_name;
        self.has_base = saved_has_base;
        self.has_traits = saved_has_traits;
        self.in_enum = saved_enum;
    }
    var members: StructMembers = .{};
    self.skipSeparators();
    // Section 12: an enum's values come first, one name at a time.
    if (enumeration) try self.parseEnumValues(name, &members);
    while (!self.check(.right_brace) and !self.check(.eof)) {
        // One member at a time, like the statements of a block: a mistake in
        // one resumes at the next, so the struct's own `}` is not then
        // reported as closing nothing (17.2).
        self.parseStructMember(name, &members) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => self.skipToNextStatement(),
        };
        self.skipSeparators();
    }
    if (self.check(.eof)) {
        return self.reportFmt(
            self.peek().span,
            "this {s} body is missing its closing `}}`",
            .{word},
            "Add `}` after the final field.",
        );
    }
    const closing = self.advance();
    try self.expectStatementEnd();
    if (enumeration and members.type_fields.items.len == 0 or
        enumeration and members.type_fields.items[0].enum_value == null)
    {
        try self.note(
            name.span,
            "an enum needs at least one value",
            try std.fmt.allocPrint(self.arena, "List its values first, one name per line, as in `enum {s} {{ first }}`.", .{self.text(name)}),
        );
    }
    return .{
        .span = spanning(keyword.span, closing.span),
        .data = .{ .struct_declaration = .{
            .class = class,
            .trait = trait,
            .enumeration = enumeration,
            .name = try self.identifier(name),
            .name_span = name.span,
            .base = base,
            .traits = try traits.toOwnedSlice(self.arena),
            .fields = try members.fields.toOwnedSlice(self.arena),
            .constructor = members.constructor,
            .methods = try members.methods.toOwnedSlice(self.arena),
            .properties = try members.properties.toOwnedSlice(self.arena),
            .type_functions = try members.type_functions.toOwnedSlice(self.arena),
            .type_fields = try members.type_fields.toOwnedSlice(self.arena),
        } },
    };
}

/// Section 12's `north`, `east`: an enum's values, each a name on its own line
/// or separated by commas, before any other member. Each becomes a `const`
/// type-level field of the enum holding that value.
fn parseEnumValues(self: *Parser, type_name: Token, members: *StructMembers) Error!void {
    while (self.startsEnumValue()) {
        const value = self.advance();
        const index: u32 = @intCast(members.type_fields.items.len);
        const value_name = try self.identifier(value);
        try members.type_fields.append(self.arena, .{
            .mutable = false,
            .name = value_name,
            .name_span = value.span,
            .annotation = .{ .name = try self.identifier(type_name), .span = type_name.span, .question_span = null },
            .initializer = try self.node(value.span, .{ .enum_value = .{ .type_name = try self.identifier(type_name), .index = index } }),
            .enum_value = index,
        });
        if (self.match(.comma) != null) {
            self.skipSeparators();
            continue;
        }
        if (!self.check(.right_brace)) try self.expectStatementEnd();
        self.skipSeparators();
    }
}

/// Whether the next member is a bare name, which in an enum is one of its
/// values.
fn startsEnumValue(self: *Parser) bool {
    if (!self.check(.identifier)) return false;
    const after = self.peekAfterNext().kind;
    return after == .newline or after == .comma or after == .right_brace or after == .eof;
}

const StructMembers = struct {
    fields: std.ArrayList(Ast.StructDeclaration.Field) = .empty,
    constructor: ?Ast.StructDeclaration.Constructor = null,
    methods: std.ArrayList(Ast.FunctionDeclaration) = .empty,
    properties: std.ArrayList(Ast.StructDeclaration.Property) = .empty,
    type_functions: std.ArrayList(Ast.StructDeclaration.TypeFunction) = .empty,
    type_fields: std.ArrayList(Ast.StructDeclaration.TypeField) = .empty,
};

/// One member of a struct body, added to `members`. `name` is the struct's.
fn parseStructMember(self: *Parser, name: Token, members: *StructMembers) Error!void {
    var annotations = try self.parseAnnotations();
    if (annotations.test_annotation) |span| {
        try self.note(span, "a test must be a top-level function", "Move this function outside the type, then keep `@test` on it.");
        annotations.test_annotation = null;
    }
    const marker = self.peek();
    if (self.in_enum and self.startsEnumValue()) {
        _ = self.advance();
        return self.reportFmt(
            marker.span,
            "`{s}` has to be listed with the other values, before any member",
            .{self.text(marker)},
            "An enum lists all its values first, so they can be read in one place. Move it up.",
        );
    }
    if (self.in_enum and marker.kind == .keyword_constructor) {
        _ = try self.parseConstructor();
        return self.note(
            marker.span,
            "an enum has no constructor",
            try std.fmt.allocPrint(self.arena, "Its values are the ones it lists, such as `{s}.{s}`, and nothing else builds one.", .{ self.text(name), if (members.type_fields.items.len > 0) members.type_fields.items[0].name else "first" }),
        );
    }
    if (self.in_trait) {
        if (annotations.abstract) |span| try self.note(
            span,
            "a trait's requirements need no `@abstract`",
            "Leave out the body instead: a member of a trait written without one is a requirement.",
        );
        annotations.abstract = null;
        if (marker.kind == .keyword_constructor) {
            _ = try self.parseConstructor();
            return self.note(
                marker.span,
                "a trait has no constructor",
                "A trait stores nothing to set up. Each type that adopts it builds its own values.",
            );
        }
        if (marker.kind == .keyword_func and self.startsTypeMember()) {
            _ = try self.parseTypeFunction(name);
            try self.expectStatementEnd();
            return self.note(
                marker.span,
                "a trait has no type-level members",
                "Declare the type-level member in each type that adopts the trait.",
            );
        }
    }
    if (annotations.override != null or annotations.abstract != null) {
        if (marker.kind == .keyword_func and self.startsTypeMember()) {
            try self.note(
                (annotations.override orelse annotations.abstract).?,
                "a type-level function cannot be overridden or abstract",
                "It belongs to its own type and is never inherited. Remove the annotation.",
            );
        } else if (marker.kind == .keyword_constructor) {
            try self.note(
                (annotations.override orelse annotations.abstract).?,
                "a constructor cannot be overridden or abstract",
                "Constructors are not inherited. A subclass declares its own and calls `super(...)` first.",
            );
        } else if (!self.in_class and !self.in_trait) {
            if (annotations.abstract) |span| {
                try self.note(span, "a struct's methods cannot be abstract", "Structs do not inherit. Remove the annotation, or declare a class.");
            } else if (!self.has_traits) {
                try self.note(
                    annotations.override.?,
                    "a struct has nothing to override",
                    "Structs do not inherit, and this one adopts no traits. Remove the annotation, or adopt the trait with `with`.",
                );
            }
        }
    }
    if (marker.kind == .keyword_func and self.startsTypeMember()) {
        try members.type_functions.append(self.arena, try self.parseTypeFunction(name));
        try self.expectStatementEnd();
        return;
    }
    if (marker.kind == .keyword_func) {
        const saved_self = self.self_allowed;
        self.self_allowed = self.memberContext();
        defer self.self_allowed = saved_self;
        const method = try self.parseMethod(annotations);
        try self.expectStatementEnd();
        try members.methods.append(self.arena, method);
        return;
    }
    if (marker.kind == .keyword_constructor) {
        // Parsed in full even when it is rejected, so the next member starts
        // after its closing brace.
        const parsed = try self.parseConstructor();
        if (members.constructor != null) {
            try self.note(
                parsed.keyword_span,
                if (self.in_class) "a class has at most one constructor" else "a struct has at most one constructor",
                try std.fmt.allocPrint(
                    self.arena,
                    "Emerald has no overloading. Build the value another way in a type-level function that calls this constructor, such as `func {s}.from_text(text: String): {s}`.",
                    .{ self.text(name), self.text(name) },
                ),
            );
            return;
        }
        members.constructor = parsed;
        return;
    }
    // Words other languages put here, answered with Emerald's spelling.
    if (marker.kind == .identifier) {
        const word = self.text(marker);
        if (std.mem.eql(u8, word, "static")) {
            // Echo the member being declared, when it can be seen.
            const keyword = if (self.index + 1 < self.tokens.len) self.tokens[self.index + 1] else marker;
            const member = if (self.index + 2 < self.tokens.len) self.tokens[self.index + 2] else marker;
            const help = if (member.kind == .identifier and (keyword.kind == .keyword_var or keyword.kind == .keyword_const))
                try std.fmt.allocPrint(self.arena, "A member that belongs to the type puts the type's name in front instead, as in `{s} {s}.{s} = ...`.", .{ self.text(keyword), self.text(name), self.text(member) })
            else if (member.kind == .identifier and keyword.kind == .keyword_func)
                try std.fmt.allocPrint(self.arena, "A member that belongs to the type puts the type's name in front instead, as in `func {s}.{s}()`.", .{ self.text(name), self.text(member) })
            else
                try std.fmt.allocPrint(self.arena, "A member that belongs to the type puts the type's name in front instead, as in `var {s}.count = 0`.", .{self.text(name)});
            return self.report(marker.span, "Emerald has no `static`", help);
        }
        if (std.mem.eql(u8, word, "init") and self.peekAfterNext().kind == .left_paren) {
            return self.report(
                marker.span,
                "a constructor is written `constructor`",
                "Write `constructor(...) { ... }`. Inside it, `self` is the value being built.",
            );
        }
        if (self.peekAfterNext().kind == .colon) {
            return self.reportFmt(
                marker.span,
                "`{s}` needs `var` or `const` in front",
                .{word},
                try std.fmt.allocPrint(self.arena, "A stored field says whether it can change, as in `var {s}: ...`.", .{word}),
            );
        }
    }
    const mutable = if (self.match(.keyword_var) != null)
        true
    else if (self.match(.keyword_const) != null)
        false
    else
        return self.reportFmt(
            marker.span,
            "expected `var` or `const` for a stored field, found {s}",
            .{marker.kind.describe()},
            "A stored field makes its binding visible, as in `var x: Float`.",
        );

    const field_name = self.peek();
    if (field_name.kind != .identifier) {
        return self.reportFmt(
            field_name.span,
            "expected a field name, found {s}",
            .{field_name.kind.describe()},
            "A stored field has a name and type, as in `var x: Float`.",
        );
    }
    _ = self.advance();
    if (self.check(.dot)) {
        if (self.in_trait) {
            _ = try self.parseTypeField(mutable, field_name, name);
            return self.note(
                field_name.span,
                "a trait has no type-level members",
                "Declare the type-level member in each type that adopts the trait.",
            );
        }
        if (self.in_class) if (annotations.override orelse annotations.abstract) |span| try self.note(
            span,
            "a type-level field cannot be overridden or abstract",
            "It belongs to its own type and is never inherited. Remove the annotation.",
        );
        try members.type_fields.append(self.arena, try self.parseTypeField(mutable, field_name, name));
        return;
    }
    if (self.match(.colon) == null) {
        if (self.check(.left_brace)) {
            return self.reportFmt(
                self.peek().span,
                "`{s}` needs a type before its body",
                .{self.text(field_name)},
                try std.fmt.allocPrint(self.arena, "A property states the type it gives, as in `const {s}: Float {{ ... }}`.", .{self.text(field_name)}),
            );
        }
        return self.reportFmt(
            self.peek().span,
            "expected `:` and a type after `{s}`, found {s}",
            .{ self.text(field_name), self.peek().kind.describe() },
            "Every stored field needs an explicit type, as in `var x: Float`.",
        );
    }
    const annotation = try self.parseTypeExpression();
    if (self.check(.left_brace)) {
        var property = try self.parseProperty(mutable, field_name, annotation);
        if (self.in_trait or self.has_traits) property.override_span = annotations.override;
        if (self.in_class) {
            property.override_span = annotations.override;
            if (annotations.abstract) |span| try self.note(
                span,
                "an abstract property is not available yet",
                "Declare an abstract method instead, such as `@abstract func area(): Float`.",
            );
        }
        try members.properties.append(self.arena, property);
        return;
    }
    // Section 11.1: a trait's `const name: String` is a requirement for
    // readable access, and `var` one for reading and assignment. Neither
    // stores anything; each is an accessor with no body, which the type that
    // adopts the trait supplies with a field or a property.
    if (self.in_trait) {
        if (self.check(.equal)) {
            _ = self.advance();
            _ = try self.parseExpression();
            try self.reportFmtNote(
                field_name.span,
                "a trait stores nothing, so `{s}` cannot have a value here",
                .{self.text(field_name)},
                try std.fmt.allocPrint(self.arena, "Leave out `= ...` so each type that adopts the trait supplies `{s}`, or give it a body that computes it.", .{self.text(field_name)}),
            );
        }
        try self.expectStatementEnd();
        const member = try self.identifier(field_name);
        var getter = accessor(member, field_name.span, &.{}, annotation, .{ .span = field_name.span, .statements = &.{} });
        getter.abstract_span = field_name.span;
        var setter: ?Ast.FunctionDeclaration = null;
        if (mutable) {
            const parameters = try self.arena.alloc(Ast.Parameter, 1);
            parameters[0] = .{ .name = "value", .name_span = field_name.span, .annotation = annotation };
            setter = accessor(member, field_name.span, parameters, null, .{ .span = field_name.span, .statements = &.{} });
            setter.?.abstract_span = field_name.span;
        }
        try members.properties.append(self.arena, .{
            .mutable = mutable,
            .name = member,
            .name_span = field_name.span,
            .annotation = annotation,
            .getter = getter,
            .setter = setter,
            .override_span = annotations.override,
        });
        return;
    }
    if (self.in_enum) {
        if (self.match(.equal) != null) _ = try self.parseExpression();
        try self.expectStatementEnd();
        return self.reportFmtNote(
            field_name.span,
            "an enum stores no fields, so `{s}` cannot be one",
            .{self.text(field_name)},
            try std.fmt.allocPrint(self.arena, "Every `{s}` is one of its values and holds nothing else. Compute it in a property instead, as in `const {s}: ... {{ ... }}`.", .{ self.text(name), self.text(field_name) }),
        );
    }
    var default: ?*const Ast.Expression = null;
    if (self.match(.equal) != null) {
        // A default may read earlier fields through `self` (10.2).
        const saved_self = self.self_allowed;
        self.self_allowed = self.memberContext();
        defer self.self_allowed = saved_self;
        default = try self.parseExpression();
    }
    try self.expectStatementEnd();
    if (self.in_class) {
        if (annotations.override) |span| try self.note(
            span,
            "a stored field cannot be overridden",
            "Only methods and properties can be replaced by a subclass. Remove `@override`, and give this field a name of its own.",
        );
        if (annotations.abstract) |span| try self.note(
            span,
            "a stored field cannot be abstract",
            "Remove `@abstract`. A field that every subclass sets can be set by the base class's constructor.",
        );
    }
    try members.fields.append(self.arena, .{
        .mutable = mutable,
        .name = try self.identifier(field_name),
        .name_span = field_name.span,
        .annotation = annotation,
        .default = default,
    });
}

/// Whether the `func` about to be parsed is followed by a name and `.`: the
/// type receiver section 10.4 writes in front of a type-level member.
/// The `self` context of a member's own code.
fn memberContext(self: *Parser) SelfContext {
    return if (self.in_class) .class_member else .member;
}

fn startsTypeMember(self: *Parser) bool {
    // Past any documentation comment on the declaration and its `func`.
    var at = self.index;
    while (self.tokens[at].kind == .doc_comment) at += 1;
    at += 1;
    if (at + 1 >= self.tokens.len) return false;
    return self.tokens[at].kind == .identifier and self.tokens[at + 1].kind == .dot;
}

/// Section 10.4: a type-level member names the type it belongs to, and the
/// type it is written inside is the only one it can name.
fn checkTypeReceiver(self: *Parser, receiver: Token, type_name: ?Token) Error!void {
    const expected = type_name orelse return;
    if (std.mem.eql(u8, try self.identifier(receiver), try self.identifier(expected))) return;
    try self.note(
        receiver.span,
        try std.fmt.allocPrint(self.arena, "this is declared inside `{s}`, not `{s}`", .{ self.text(expected), self.text(receiver) }),
        try std.fmt.allocPrint(
            self.arena,
            "A type-level member names the type it is written in. Write `{s}.` here.",
            .{self.text(expected)},
        ),
    );
}

/// `func Vector2.origin(): Vector2 { ... }`. `type_name` is the struct it is
/// written inside, or null when it is written outside any.
fn parseTypeFunction(self: *Parser, type_name: ?Token) Error!Ast.StructDeclaration.TypeFunction {
    _ = self.advance(); // `func`
    const receiver = self.advance();
    _ = self.advance(); // `.`
    const member = self.peek();
    if (member.kind != .identifier) {
        return self.reportFmt(
            member.span,
            "expected a name after `{s}.`, found {s}",
            .{ self.text(receiver), member.kind.describe() },
            "A type-level function is named after its type, as in `func Vector2.origin()`.",
        );
    }
    _ = self.advance();
    try self.checkTypeReceiver(receiver, type_name);

    const member_name = try self.identifier(member);
    const full_name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ try self.identifier(receiver), member_name });
    const parameters = try self.parseParameterList(
        full_name,
        "Every function declares its parameters in parentheses, even when there are none.",
    );
    var return_annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) return_annotation = try self.parseTypeExpression();

    const saved_self = self.self_allowed;
    self.self_allowed = .type_member;
    defer self.self_allowed = saved_self;
    const body = try self.parseBlock();

    return .{
        .member = member_name,
        .member_span = member.span,
        .declaration = .{
            .name = full_name,
            .name_span = spanning(receiver.span, member.span),
            .parameters = parameters,
            .return_annotation = return_annotation,
            .body = body,
        },
    };
}

/// `var Player.count = 0`, with the parser just past `Player`.
fn parseTypeField(
    self: *Parser,
    mutable: bool,
    receiver: Token,
    type_name: Token,
) Error!Ast.StructDeclaration.TypeField {
    _ = self.advance(); // `.`
    const member = self.peek();
    if (member.kind != .identifier) {
        return self.reportFmt(
            member.span,
            "expected a name after `{s}.`, found {s}",
            .{ self.text(receiver), member.kind.describe() },
            "A type-level field is named after its type, as in `var Player.count = 0`.",
        );
    }
    _ = self.advance();
    try self.checkTypeReceiver(receiver, type_name);

    var annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) annotation = try self.parseTypeExpression();
    const saved_self = self.self_allowed;
    self.self_allowed = .type_member;
    defer self.self_allowed = saved_self;

    // Both mistakes below are noted rather than reported, with the rest of
    // the declaration still read, so the struct body carries on normally.
    var initializer: *const Ast.Expression = undefined;
    if (self.check(.left_brace)) {
        const opening = self.peek().span;
        _ = try self.parseBlock();
        try self.note(
            opening,
            "a type-level property is not available",
            "Use a type-level function instead, as in `func Player.total(): Int { ... }`.",
        );
        initializer = try self.node(opening, .{ .nothing_literal = {} });
    } else if (self.match(.equal) == null) {
        try self.note(
            spanning(receiver.span, member.span),
            try std.fmt.allocPrint(self.arena, "`{s}.{s}` needs its value here", .{ self.text(receiver), self.text(member) }),
            "A type-level field is set up once, from the value after `=`, as in `var Player.count = 0`.",
        );
        initializer = try self.node(member.span, .{ .nothing_literal = {} });
    } else {
        initializer = try self.parseExpression();
    }
    try self.expectStatementEnd();

    return .{
        .mutable = mutable,
        .name = try self.identifier(member),
        .name_span = spanning(receiver.span, member.span),
        .annotation = annotation,
        .initializer = initializer,
    };
}

/// Section 10.3. A `const` property's braces hold its getter's body directly;
/// a `var` property's hold a `get` block and a `set` block.
fn parseProperty(
    self: *Parser,
    mutable: bool,
    name_token: Token,
    annotation: Ast.TypeExpression,
) Error!Ast.StructDeclaration.Property {
    const name = try self.identifier(name_token);
    const saved_self = self.self_allowed;
    self.self_allowed = self.memberContext();
    defer self.self_allowed = saved_self;

    const accessor_form = self.startsAccessor(self.index + 1);
    if (!mutable and !accessor_form) {
        const body = try self.parseBlock();
        try self.expectStatementEnd();
        return .{
            .mutable = false,
            .name = name,
            .name_span = name_token.span,
            .annotation = annotation,
            .getter = accessor(name, name_token.span, &.{}, annotation, body),
            .setter = null,
        };
    }

    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();
    var get_body: ?Ast.Block = null;
    var set_body: ?Ast.Block = null;
    self.skipSeparators();
    while (!self.check(.right_brace) and !self.check(.eof)) {
        if (!self.startsAccessor(self.index)) {
            return self.reportFmt(
                self.peek().span,
                "expected `get` or `set` in the property `{s}`, found {s}",
                .{ name, self.peek().kind.describe() },
                "A `var` property holds a `get` block that returns its value and a `set` block that receives the new one as `value`.",
            );
        }
        const word = self.advance();
        const is_get = std.mem.eql(u8, self.text(word), "get");
        const body = try self.parseBlock();
        const slot = if (is_get) &get_body else &set_body;
        if (slot.* != null) {
            try self.note(word.span, "this property already has this block", "Keep one `get` block and one `set` block.");
        }
        slot.* = body;
        self.skipSeparators();
    }
    const closing = self.peek();
    if (closing.kind != .right_brace) {
        return self.reportFmt(
            closing.span,
            "expected `}}` to close the property `{s}`, found {s}",
            .{ name, closing.kind.describe() },
            "A `var` property holds exactly a `get` block and a `set` block.",
        );
    }
    _ = self.advance();
    try self.expectStatementEnd();

    const empty: Ast.Block = .{ .span = closing.span, .statements = &.{} };
    if (!mutable) {
        try self.note(
            name_token.span,
            "a `const` property has no `get` or `set` blocks",
            "Its braces hold the getter's body directly, as in `const area: Float { return self.width * self.height }`. Use `var` for a property that can be set.",
        );
    } else {
        if (get_body == null) {
            try self.note(name_token.span, "this property has no `get` block", "Add `get { return ... }`, which runs whenever the property is read.");
        }
        if (set_body == null) {
            try self.note(
                name_token.span,
                "this `var` property has no `set` block",
                "Add `set { ... }`, which receives the new value as `value`, or make it a `const` property if it is only read.",
            );
        }
    }

    const parameters = try self.arena.alloc(Ast.Parameter, 1);
    parameters[0] = .{ .name = "value", .name_span = name_token.span, .annotation = annotation };
    return .{
        .mutable = mutable,
        .name = name,
        .name_span = name_token.span,
        .annotation = annotation,
        .getter = accessor(name, name_token.span, &.{}, annotation, get_body orelse empty),
        .setter = if (mutable) accessor(name, name_token.span, parameters, null, set_body orelse empty) else null,
    };
}

/// Whether the tokens at `at` are `get {` or `set {`. Neither word is a
/// keyword, so this is the one place they mean anything.
fn startsAccessor(self: *Parser, at: usize) bool {
    if (at + 1 >= self.tokens.len) return false;
    const word = self.tokens[at];
    if (word.kind != .identifier or self.tokens[at + 1].kind != .left_brace) return false;
    const spelled = self.text(word);
    return std.mem.eql(u8, spelled, "get") or std.mem.eql(u8, spelled, "set");
}

fn accessor(
    name: []const u8,
    span: Source.Span,
    parameters: []const Ast.Parameter,
    result: ?Ast.TypeExpression,
    body: Ast.Block,
) Ast.FunctionDeclaration {
    return .{ .name = name, .name_span = span, .parameters = parameters, .return_annotation = result, .body = body };
}

/// Section 10.2: `constructor(x: Float) { self.x = x }`.
fn parseConstructor(self: *Parser) Error!Ast.StructDeclaration.Constructor {
    const keyword = self.advance();
    // A parameter's default may read `self` (7.3), as a method's may; the
    // checker decides which fields it can see.
    const saved_self = self.self_allowed;
    self.self_allowed = self.memberContext();
    defer self.self_allowed = saved_self;
    const parameters = try self.parseParameterList(
        "constructor",
        "A constructor declares its parameters in parentheses, even when there are none.",
    );

    if (self.match(.colon)) |colon| {
        const annotation = try self.parseTypeExpression();
        try self.note(
            spanning(colon.span, annotation.span),
            "a constructor has no return type",
            "It always produces the value being built. Remove the `:` and the type.",
        );
    }

    const body = try self.parseBlock();
    try self.expectStatementEnd();

    return .{ .keyword_span = keyword.span, .parameters = parameters, .body = body };
}

/// `for (name, age) in entries`, which unpacks each value it visits.
fn parseDestructuringFor(self: *Parser, keyword: Token) Error!Ast.Statement {
    const pattern = try self.parsePattern();

    if (self.match(.keyword_in) == null) {
        return self.reportFmt(
            self.peek().span,
            "expected `in` after these names, found {s}",
            .{self.peek().kind.describe()},
            "Write what to loop over after `in`, as in `for (name, age) in entries`.",
        );
    }

    const iterable = try self.parseHeaderExpression();
    const body = try self.parseBlock();
    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .for_loop = .{
            .name = "",
            .name_span = pattern.span,
            .pattern = pattern,
            .iterable = iterable,
            .body = body,
        } },
    };
}

/// Section 14.2: `using Shapes`, or `using UiColor = Graphics.Color`.
///
/// A namespace is written in `PascalCase` and a declaration in `snake_case`, but
/// both are ordinary identifiers here; which one a path names is a question for
/// the resolver, which is the pass that knows what exists.
fn parseUsing(self: *Parser) Error!Ast.Using {
    const keyword = self.advance();

    var first = try self.expectName("expected a name after `using`");
    var alias: []const u8 = "";
    var alias_span: Source.Span = .{ .start = 0, .end = 0 };

    if (self.match(.equal)) |_| {
        alias = try self.identifier(first);
        alias_span = first.span;
        first = try self.expectName("expected a name after `=`");
    }

    var path: std.ArrayList([]const u8) = .empty;
    try path.append(self.arena, try self.identifier(first));
    var last = first.span;
    while (self.match(.dot)) |_| {
        const segment = try self.expectName("expected a name after `.`");
        try path.append(self.arena, try self.identifier(segment));
        last = segment.span;
    }

    try self.expectStatementEnd();
    return .{
        .span = spanning(keyword.span, last),
        .alias = alias,
        .alias_span = alias_span,
        .path = try path.toOwnedSlice(self.arena),
        .path_span = spanning(first.span, last),
    };
}

fn expectName(self: *Parser, message: []const u8) Error!Token {
    if (self.check(.identifier)) return self.advance();
    return self.reportFmt(
        self.peek().span,
        "{s}, found {s}",
        .{ message, self.peek().kind.describe() },
        "A `using` declaration names a namespace, such as `using Shapes`, or one name in it.",
    );
}

/// Section 6.4: `while condition { body }`.
fn parseWhile(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const condition = try self.parseHeaderExpression();
    const body = try self.parseBlock();
    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .while_loop = .{ .condition = condition, .body = body } },
    };
}

/// Section 6.4: `for name in iterable { body }`.
fn parseFor(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();

    // Section 8.2's `for (name, age) in entries`.
    if (self.startsPattern()) return self.parseDestructuringFor(keyword);

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

    const iterable = try self.parseHeaderExpression();
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
/// A method, which in a class may carry `@override`, or `@abstract` in place
/// of its body (10.7).
fn parseMethod(self: *Parser, annotations: Annotations) Error!Ast.FunctionDeclaration {
    if (self.in_trait) {
        // Section 11.1: without a body, a requirement; with one, a default.
        var method = (try self.parseFunctionDeclarationWith(true, .optional)).data.function_declaration;
        method.override_span = annotations.override;
        return method;
    }
    const abstract = self.in_class and annotations.abstract != null;
    var method = (try self.parseFunctionDeclarationWith(true, if (abstract) .forbidden else .required)).data.function_declaration;
    if (self.in_class) {
        method.override_span = annotations.override;
        method.abstract_span = annotations.abstract;
    } else if (self.has_traits) {
        method.override_span = annotations.override;
    }
    return method;
}

fn parseFunctionDeclaration(self: *Parser) Error!Ast.Statement {
    return self.parseFunctionDeclarationWith(false, .required);
}

/// Whether a function's body may be left out: never, only for an `@abstract`
/// method, which then may not have one, or for a trait's method, which
/// becomes a requirement without one.
const Body = enum { required, forbidden, optional };

/// `method` is whether this is a member of a type.
fn parseFunctionDeclarationWith(self: *Parser, method: bool, body_rule: Body) Error!Ast.Statement {
    const abstract = body_rule != .required;
    const keyword = self.advance();

    const name = self.peek();
    if (name.kind == .keyword_constructor) {
        return self.report(
            name.span,
            "a constructor is written without `func`",
            if (self.in_class) "Write `constructor(...) { ... }` directly inside the class." else "Write `constructor(...) { ... }` directly inside the struct.",
        );
    }
    if (name.kind != .identifier) {
        return self.reportFmt(
            name.span,
            "expected a name after `func`, found {s}",
            .{name.kind.describe()},
            "A function declaration needs a name, as in `func greet() { }`.",
        );
    }
    _ = self.advance();

    const parameters = try self.parseParameterList(
        self.text(name),
        "Every function declares its parameters in parentheses, even when there are none.",
    );

    var return_annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) return_annotation = try self.parseTypeExpression();

    if (abstract and !self.check(.left_brace)) {
        const end = if (return_annotation) |annotation| annotation.span else name.span;
        return .{
            .span = spanning(keyword.span, end),
            .data = .{ .function_declaration = .{
                .name = try self.identifier(name),
                .name_span = name.span,
                .parameters = parameters,
                .return_annotation = return_annotation,
                .body = .{ .span = end, .statements = &.{} },
                .abstract_span = name.span,
            } },
        };
    }
    if (body_rule == .forbidden) {
        try self.reportFmtNote(
            self.peek().span,
            "`{s}` is abstract, so it has no body",
            .{self.text(name)},
            "Remove the body, and let each subclass supply one with `@override`. Or remove `@abstract` to keep this body.",
        );
    } else if (body_rule == .required and method and self.in_class and self.check(.newline)) {
        return self.reportFmt(
            self.peek().span,
            "`{s}` needs a body",
            .{self.text(name)},
            "Add its body in braces. A method that each subclass supplies instead is marked `@abstract`, in an `@abstract` class.",
        );
    }

    const body = try self.parseBlock();

    return .{
        .span = spanning(keyword.span, body.span),
        .data = .{ .function_declaration = .{
            .name = try self.identifier(name),
            .name_span = name.span,
            .parameters = parameters,
            .return_annotation = return_annotation,
            .body = body,
        } },
    };
}

/// `(count: Int, label: String)`, after whatever `after` names.
fn parseParameterList(self: *Parser, after: []const u8, missing_help: []const u8) Error![]const Ast.Parameter {
    const opening = self.peek();
    if (opening.kind != .left_paren) {
        return self.reportFmt(
            opening.span,
            "expected `(` after `{s}`, found {s}",
            .{ after, opening.kind.describe() },
            missing_help,
        );
    }
    _ = self.advance();

    var parameters: std.ArrayList(Ast.Parameter) = .empty;
    var first_default: ?[]const u8 = null;
    // Required parameters written after a defaulted one, with the first
    // defaulted name, reported once the whole list is known.
    var misplaced: std.ArrayList(struct { parameter: Ast.Parameter, defaulted: []const u8 }) = .empty;
    if (!self.check(.right_paren)) {
        while (true) {
            const parameter = try self.parseParameter();
            // Section 7.3: "Default-valued parameters follow required
            // parameters." Otherwise a positional call could never reach the
            // required one without also passing the default.
            if (parameter.default != null) {
                if (first_default == null) first_default = parameter.name;
            } else if (first_default) |defaulted| {
                try misplaced.append(self.arena, .{ .parameter = parameter, .defaulted = defaulted });
            }
            try parameters.append(self.arena, parameter);
            if (self.match(.comma) == null) break;
        }
    }
    for (misplaced.items) |entry| {
        // The one exception: a final function parameter, which section 7.4's
        // trailing block reaches whatever the defaults before it were left as.
        const last = &parameters.items[parameters.items.len - 1];
        if (std.mem.eql(u8, entry.parameter.name, last.name) and entry.parameter.name_span.start == last.name_span.start and
            last.annotation.signature != null) continue;
        try self.note(
            entry.parameter.name_span,
            try std.fmt.allocPrint(self.arena, "`{s}` has no default, so it cannot follow `{s}`, which has one", .{ entry.parameter.name, entry.defaulted }),
            "Move the parameters with defaults to the end, or give this one a default too. Only a final function parameter, which a trailing block can supply, may follow them.",
        );
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
    return parameters.toOwnedSlice(self.arena);
}

fn parseParameter(self: *Parser) Error!Ast.Parameter {
    const name = self.peek();
    if (name.kind == .keyword_self) {
        return self.report(
            name.span,
            "`self` is not listed as a parameter",
            "Every method and constructor already has `self`. Remove it from the parameter list.",
        );
    }
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
        return self.reportFmt(
            self.peek().span,
            "`{s}` needs a type before its default",
            .{self.text(name)},
            "Write the type first, as in `count: Int = 0`.",
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
    const default: ?*const Ast.Expression = if (self.match(.equal) != null) try self.parseExpression() else null;
    return .{ .name = try self.identifier(name), .name_span = name.span, .annotation = annotation, .default = default };
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

fn parseRaise(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const next = self.peek();
    const value = switch (next.kind) {
        .newline, .eof, .right_brace, .keyword_if => null,
        else => try self.parseExpression(),
    };
    return self.finishSimpleStatement(.{
        .span = if (value) |v| spanning(keyword.span, v.span) else keyword.span,
        .data = .{ .raise_statement = .{ .keyword_span = keyword.span, .value = value } },
    });
}

fn parseAssert(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const condition = try self.parseExpression();
    const message = if (self.match(.comma) != null) try self.parseExpression() else null;
    return self.finishSimpleStatement(.{
        .span = if (message) |m| spanning(keyword.span, m.span) else spanning(keyword.span, condition.span),
        .data = .{ .assert_statement = .{ .keyword_span = keyword.span, .condition = condition, .message = message } },
    });
}

fn parseTry(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const body = try self.parseBlock();
    var catches: std.ArrayList(Ast.Catch) = .empty;
    var cleanup: ?Ast.Block = null;
    var end = body.span;
    while (self.peekPastNewlines().kind == .keyword_catch) {
        self.skipSeparators();
        const catch_keyword = self.advance();
        const name = self.peek();
        if (name.kind != .identifier) return self.report(name.span, "expected a name after `catch`", "Name the caught error, as in `catch error: FileError {`.");
        _ = self.advance();
        var annotation: ?Ast.TypeExpression = null;
        if (self.match(.colon) != null) annotation = try self.parseTypeExpression();
        const catch_body = try self.parseBlock();
        try catches.append(self.arena, .{
            .keyword_span = catch_keyword.span,
            .name = try self.identifier(name),
            .name_span = name.span,
            .annotation = annotation,
            .body = catch_body,
        });
        end = catch_body.span;
    }
    if (self.peekPastNewlines().kind == .keyword_finally) {
        self.skipSeparators();
        _ = self.advance();
        cleanup = try self.parseBlock();
        end = cleanup.?.span;
    }
    if (catches.items.len == 0 and cleanup == null) return self.report(body.span, "`try` needs a `catch` or `finally`", "Add a handler with `catch error { ... }`, cleanup with `finally { ... }`, or remove `try`.");
    return .{
        .span = spanning(keyword.span, end),
        .data = .{ .try_statement = .{
            .keyword_span = keyword.span,
            .body = body,
            .catches = try catches.toOwnedSlice(self.arena),
            .finally_block = cleanup,
        } },
    };
}

/// Section 4.3: `var` permits rebinding, `const` does not. Both introduce one
/// binding at a time, which section 5.2 states directly.
fn parseDeclaration(self: *Parser, mutable: bool) Error!Ast.Statement {
    const keyword = self.advance();

    // Section 8.2's `var (name, age) = entry`.
    if (self.startsPattern()) return self.parseDestructuring(keyword, mutable);

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

/// Section 8.2's `var (name, age) = entry`. The annotation, when there is one,
/// is the tuple's type: there is nowhere for a position to carry its own.
fn parseDestructuring(self: *Parser, keyword: Token, mutable: bool) Error!Ast.Statement {
    const pattern = try self.parsePattern();

    var annotation: ?Ast.TypeExpression = null;
    if (self.match(.colon) != null) annotation = try self.parseTypeExpression();

    const equals = self.peek();
    if (equals.kind != .equal) {
        return self.reportFmt(
            equals.span,
            "expected `=` after these names, found {s}",
            .{equals.kind.describe()},
            "Unpacking needs a tuple to unpack, as in `var (name, age) = entry`.",
        );
    }
    _ = self.advance();

    const initializer = try self.parseExpression();
    try self.expectStatementEnd();

    return .{
        .span = spanning(keyword.span, initializer.span),
        .data = .{ .destructuring = .{
            .mutable = mutable,
            .pattern = pattern,
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
    if (token.kind == .left_brace) return self.parseSetType();
    if (token.kind == .left_paren) return self.parseTupleType();
    if (token.kind == .keyword_func) return self.parseFunctionType();
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
    }

    // Section 14.2: the fully qualified spelling that resolves a collision is
    // valid anywhere a type is written, not only at a constructor call.
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(self.arena, written);
    while (self.check(.dot)) {
        _ = self.advance();
        const segment = self.peek();
        if (segment.kind != .identifier) {
            return self.reportFmt(
                segment.span,
                "expected a type name after `.`, found {s}",
                .{segment.kind.describe()},
                "Write the complete qualified type, as in `Shapes.Marker`.",
            );
        }
        _ = self.advance();
        var part = try self.identifier(segment);
        if (std.mem.endsWith(u8, part, "?")) {
            question = .{ .start = segment.span.end - 1, .end = segment.span.end };
            part = part[0 .. part.len - 1];
            span.end = segment.span.end - 1;
        } else {
            span.end = segment.span.end;
        }
        try path.append(self.arena, '.');
        try path.appendSlice(self.arena, part);
    }
    written = try path.toOwnedSlice(self.arena);

    if (question == null and self.check(.question)) {
        // A `?` that could not attach to a name, as in `[String]?`.
        question = self.advance().span;
    }
    try self.rejectNestedOptional(question);

    return .{ .span = span, .name = written, .question_span = question };
}

/// Section 4.5: optionals never nest, so a second `?` is a mistake with a
/// specific explanation rather than a stray token.
fn rejectNestedOptional(self: *Parser, question: ?Source.Span) Error!void {
    if (question == null) return;
    if (!self.check(.question)) return;
    return self.report(
        spanning(question.?, self.peek().span),
        "a type cannot be optional twice",
        "One `?` already says the value may be absent; there is nothing for a second to add.",
    );
}

/// Section 8.2's `(String, Int)`, and `(String, Int)?` for an optional tuple.
fn parseTupleType(self: *Parser) Error!Ast.TypeExpression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    var positions: std.ArrayList(Ast.TypeExpression) = .empty;
    while (true) {
        self.skipSeparators();
        try positions.append(self.arena, try self.parseTypeExpression());
        self.skipSeparators();
        if (self.match(.comma) == null) break;
        self.skipSeparators();
        if (self.check(.right_paren)) break; // a trailing comma
    }

    const closing = self.peek();
    if (closing.kind != .right_paren) {
        return self.reportFmt(
            closing.span,
            "expected `)` to close this tuple type, found {s}",
            .{closing.kind.describe()},
            "Separate the position types with commas, as in `(String, Int)`.",
        );
    }
    _ = self.advance();

    if (positions.items.len < 2) {
        return self.report(
            spanning(opening.span, closing.span),
            "a tuple type needs at least two positions",
            "A tuple holds at least two values. Drop the parentheses to write a single type.",
        );
    }

    var span = spanning(opening.span, closing.span);
    var question: ?Source.Span = null;
    if (self.check(.question)) question = self.advance().span;
    try self.rejectNestedOptional(question);
    if (question) |mark| span = spanning(span, mark);

    return .{
        .span = span,
        .name = "",
        .positions = try positions.toOwnedSlice(self.arena),
        .question_span = question,
    };
}

/// Section 8.2's `[T]`, and `[T]?` for an optional list.
fn parseListType(self: *Parser) Error!Ast.TypeExpression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    const first = try self.arena.create(Ast.TypeExpression);
    first.* = try self.parseTypeExpression();

    // Section 8.2's `[String: Int]`, told from `[String]` by the colon.
    var key: ?*const Ast.TypeExpression = null;
    var element = first;
    if (self.match(.colon) != null) {
        key = first;
        element = try self.arena.create(Ast.TypeExpression);
        element.* = try self.parseTypeExpression();
    }

    const closing = self.peek();
    if (closing.kind != .right_bracket) {
        return self.reportFmt(
            closing.span,
            "expected `]` to close this {s} type, found {s}",
            .{ if (key == null) "list" else "dictionary", closing.kind.describe() },
            "A list type is an element type in brackets, as in `[Int]`, and a dictionary type names both, as in `[String: Int]`.",
        );
    }
    _ = self.advance();

    const question: ?Source.Span = if (self.match(.question)) |token| token.span else null;
    try self.rejectNestedOptional(question);
    return .{
        .span = spanning(opening.span, closing.span),
        .name = "",
        .element = element,
        .key = key,
        .question_span = question,
    };
}

/// Section 8.2's `{String}`. Braces are unambiguous in a type position, which
/// is why the set type keeps them while its literal uses brackets.
fn parseSetType(self: *Parser) Error!Ast.TypeExpression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    const element = try self.arena.create(Ast.TypeExpression);
    element.* = try self.parseTypeExpression();

    const closing = self.peek();
    if (closing.kind != .right_brace) {
        return self.reportFmt(
            closing.span,
            "expected `}}` to close this set type, found {s}",
            .{closing.kind.describe()},
            "A set type is a member type in braces, as in `{String}`.",
        );
    }
    _ = self.advance();

    const question: ?Source.Span = if (self.match(.question)) |token| token.span else null;
    try self.rejectNestedOptional(question);
    return .{
        .span = spanning(opening.span, closing.span),
        .name = "",
        .element = element,
        .set = true,
        .question_span = question,
    };
}

/// Section 7.1's `func(Int, String): Bool`. A function type reuses declaration
/// syntax, so the only difference from a declaration is that it names nothing.
fn parseFunctionType(self: *Parser) Error!Ast.TypeExpression {
    const keyword = self.advance();
    const opening = self.peek();
    if (opening.kind != .left_paren) {
        return self.reportFmt(
            opening.span,
            "expected `(` after `func` in a type, found {s}",
            .{opening.kind.describe()},
            "A function type lists what it takes in parentheses, as in `func(Int): String`.",
        );
    }
    try self.nest(opening.span);
    defer self.unnest();
    _ = self.advance();

    var parameters: std.ArrayList(Ast.TypeExpression) = .empty;
    if (!self.check(.right_paren)) {
        while (true) {
            try parameters.append(self.arena, try self.parseTypeExpression());
            if (self.match(.comma) == null) break;
        }
    }

    const closing = self.peek();
    if (closing.kind != .right_paren) {
        return self.reportFmt(
            closing.span,
            "expected `)` to close this function type, found {s}",
            .{closing.kind.describe()},
            "A function type lists what it takes in parentheses, as in `func(Int): String`.",
        );
    }
    _ = self.advance();

    // Section 7.1 omits the result when there is none, which is `Nothing`.
    var result: ?*const Ast.TypeExpression = null;
    var last = closing.span;
    if (self.match(.colon) != null) {
        const written = try self.arena.create(Ast.TypeExpression);
        written.* = try self.parseTypeExpression();
        last = written.span;
        result = written;
    }

    const signature = try self.arena.create(Ast.SignatureExpression);
    signature.* = .{ .parameters = try parameters.toOwnedSlice(self.arena), .result = result };

    const question: ?Source.Span = if (self.match(.question)) |token| token.span else null;
    try self.rejectNestedOptional(question);
    return .{
        .span = spanning(keyword.span, last),
        .name = "",
        .signature = signature,
        .question_span = question,
    };
}

fn parseIf(self: *Parser) Error!Ast.Statement {
    const keyword = self.advance();
    const condition = try self.parseHeaderExpression();
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

/// Section 6.3's `case subject { when a, b { ... } else { ... } }`, or with
/// `then value` in place of each block. The caller decides which form it
/// allows where it is written.
fn parseCase(self: *Parser) Error!*const Ast.Case {
    const keyword = self.advance();
    const subject: ?*const Ast.Expression = if (self.check(.left_brace)) null else try self.parseHeaderExpression();
    const opening = self.peek();
    if (opening.kind != .left_brace) {
        return self.reportFmt(
            opening.span,
            "expected `{{` after the `case` subject, found {s}",
            .{opening.kind.describe()},
            "A `case` lists its arms in braces, each starting with `when`.",
        );
    }
    try self.nest(opening.span);
    defer self.unnest();
    _ = self.advance();

    // The arms are expressions and blocks inside, whatever surrounds the case.
    const saved_header = self.in_control_header;
    self.in_control_header = false;
    defer self.in_control_header = saved_header;

    var parts: CaseParts = .{};
    // A mistake in an arm is reported once, and the rest of the `case` is
    // stepped over, so its closing `}` is not reported as closing nothing.
    self.parseCaseArms(opening, subject == null, &parts) catch |err| {
        if (err == error.ParseFailed) self.skipPastBraces();
        return err;
    };
    const closing = self.advance();
    if (parts.arms.items.len == 0) {
        return self.report(
            spanning(keyword.span, closing.span),
            "this `case` has no `when` arms",
            "Add an arm for each value to match, as in `when 1 { ... }`.",
        );
    }
    const built = try self.arena.create(Ast.Case);
    built.* = .{
        .keyword_span = keyword.span,
        .subject = subject,
        .arms = try parts.arms.toOwnedSlice(self.arena),
        .otherwise = parts.otherwise,
        .else_span = parts.else_span,
    };
    return built;
}

const CaseParts = struct {
    arms: std.ArrayList(Ast.Case.Arm) = .empty,
    otherwise: ?Ast.Case.Body = null,
    else_span: ?Source.Span = null,
    produces: ?bool = null,
};

/// The arms of a `case`, up to but not including its closing `}`.
fn parseCaseArms(self: *Parser, opening: Token, subjectless: bool, parts: *CaseParts) Error!void {
    const arms = &parts.arms;
    const otherwise = &parts.otherwise;
    const else_span = &parts.else_span;
    const produces = &parts.produces;
    while (true) {
        self.skipSeparators();
        const token = self.peek();
        if (token.kind == .right_brace) break;
        if (token.kind == .eof) {
            return self.report(opening.span, "this `case` is never closed", "Add the closing `}` after its last arm.");
        }
        if (otherwise.* != null) {
            return self.report(
                token.span,
                "nothing can follow the `else` arm",
                "`else` catches everything the arms above it did not, so it comes last. Move this arm above it.",
            );
        }
        if (token.kind == .keyword_else) {
            _ = self.advance();
            else_span.* = token.span;
            otherwise.* = try self.parseCaseBody(produces);
            continue;
        }
        if (token.kind != .keyword_when) {
            return self.reportFmt(
                token.span,
                "expected `when` or `else` in this `case`, found {s}",
                .{token.kind.describe()},
                "Each arm of a `case` starts with `when` and what it matches, as in `when 1 { ... }`.",
            );
        }
        _ = self.advance();
        var alternatives: std.ArrayList(*const Ast.Expression) = .empty;
        while (true) {
            try alternatives.append(self.arena, try self.parseHeaderExpression());
            const comma = self.match(.comma) orelse break;
            if (subjectless) {
                return self.report(
                    comma.span,
                    "a `case` without a subject takes one condition per `when`",
                    "Each `when` here is a `Bool` condition. Join several with `or`.",
                );
            }
        }
        try arms.append(self.arena, .{
            .when_span = token.span,
            .alternatives = try alternatives.toOwnedSlice(self.arena),
            .body = try self.parseCaseBody(produces),
        });
    }
}

/// A block, or `then` and a value, which has to agree with the arms before it
/// (`produces`, null before the first).
fn parseCaseBody(self: *Parser, produces: *?bool) Error!Ast.Case.Body {
    const body: Ast.Case.Body = if (self.match(.keyword_then) != null)
        .{ .value = try self.parseExpression() }
    else if (self.check(.left_brace))
        .{ .block = try self.parseBlock() }
    else
        return self.reportFmt(
            self.peek().span,
            "expected a block or `then` after what this arm matches, found {s}",
            .{self.peek().kind.describe()},
            "Give the arm a block in braces, or `then` and the value it produces.",
        );
    const value = body == .value;
    if (produces.*) |earlier| {
        if (earlier != value) {
            return self.report(
                switch (body) {
                    .value => |expression| expression.span,
                    .block => |block| block.span,
                },
                if (earlier) "this arm has a block, but the arms above it use `then`" else "this arm uses `then`, but the arms above it have blocks",
                "A `case` either runs a block for each arm or produces a value from each with `then`. Write every arm the same way.",
            );
        }
    }
    produces.* = value;
    if (value) {
        const after = self.peek().kind;
        if (after != .newline and after != .right_brace) {
            return self.reportFmt(
                self.peek().span,
                "expected the end of the arm, found {s}",
                .{self.peek().kind.describe()},
                "Each `then` arm is one value on its line. Start the next arm on a new line.",
            );
        }
    }
    return body;
}

/// Section 3.4: braces delimit blocks, and a block is only ever part of a
/// declared construct. There is no standalone anonymous block.
/// The condition of an `if` or `while`, or the iterable of a `for`, where the
/// `{` that follows opens the body.
fn parseHeaderExpression(self: *Parser) Error!*const Ast.Expression {
    const saved = self.in_control_header;
    self.in_control_header = true;
    defer self.in_control_header = saved;
    return self.parseExpression();
}

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

    // Section 7.4: in an `if`, `while`, or `for` header the `{` opens the body,
    // so a trailing block written there was read as the body instead. Its `=>`
    // is the giveaway, and saying so here is far clearer than the errors the
    // parameters would otherwise produce as statements.
    if (self.startsLambdaHeader()) {
        self.skipPastBraces();
        return self.report(
            opening.span,
            "this `{` opens the body, so the block before it has nowhere to go",
            "Put the call in parentheses so the block belongs to it, as in `if (items.any? { item => item.valid?() }) {`.",
        );
    }

    // Every block, not only a function body: a declaration inside a top-level
    // `if` is just as nested.
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
    return self.finishStatementFrom(start, try self.parseExpression());
}

/// The rest of a simple statement, once its first expression is parsed. Split
/// out because a lambda written on one line has to see that expression before
/// it can tell a body that produces a value from a body that does something.
fn finishStatementFrom(
    self: *Parser,
    start: Token,
    expression: *const Ast.Expression,
) Error!Ast.Statement {
    if (assignmentOperator(self.peek().kind)) |assignment| {
        // Section 8.2's `(left, right) = (right, left)`. It is recognized after
        // the fact, because a statement beginning with `(` is an expression
        // until an `=` says otherwise.
        if (expression.data == .tuple_literal and assignment.operation == null) {
            return self.finishDestructuringAssignment(start, expression);
        }

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
                .steps = target.steps,
                .target_span = expression.span,
                .operation = assignment.operation,
                .value = value,
            } },
        });
    }

    return self.finishExpressionStatement(expression);
}

/// Section 8.2's `(left, right) = (right, left)`, recognized from the start.
fn parseDestructuringAssignment(self: *Parser) Error!Ast.Statement {
    const start = self.peek();
    const pattern = try self.parsePattern();
    _ = self.advance(); // the `=`, which `startsPatternAssignment` has seen

    const value = try self.parseExpression();
    if (assignmentOperator(self.peek().kind) != null) {
        return self.report(
            self.peek().span,
            "assignments cannot be chained",
            "Write each assignment on its own line.",
        );
    }

    return self.finishSimpleStatement(.{
        .span = spanning(start.span, value.span),
        .data = .{ .destructuring_assignment = .{ .pattern = pattern, .value = value } },
    });
}

/// The same, reached the other way: the left side parsed as a tuple literal
/// because it held something that is not a name, so this is where that is
/// reported. Section 8.2 allows local names and `_` as destinations; a
/// field or index destination is deferred, so anything else is reported here.
fn finishDestructuringAssignment(
    self: *Parser,
    start: Token,
    left: *const Ast.Expression,
) Error!Ast.Statement {
    _ = self.advance();

    const pattern = try self.patternOfTuple(left);
    const value = try self.parseExpression();
    if (assignmentOperator(self.peek().kind) != null) {
        return self.report(
            self.peek().span,
            "assignments cannot be chained",
            "Write each assignment on its own line.",
        );
    }

    return self.finishSimpleStatement(.{
        .span = spanning(start.span, value.span),
        .data = .{ .destructuring_assignment = .{
            .pattern = pattern,
            .value = value,
        } },
    });
}

/// The names a tuple literal on the left of `=` assigns to, nested tuples
/// included (7.4).
fn patternOfTuple(self: *Parser, left: *const Ast.Expression) Error!Ast.Pattern {
    var positions: std.ArrayList(Ast.Pattern.Position) = .empty;
    var names: std.ArrayList(Ast.Pattern.Name) = .empty;
    for (left.data.tuple_literal) |position| {
        switch (position.data) {
            .name => |written| {
                const name: Ast.Pattern.Name = .{ .text = written, .span = position.span };
                try positions.append(self.arena, .{ .name = name });
                try names.append(self.arena, name);
            },
            .tuple_literal => {
                const nested = try self.arena.create(Ast.Pattern);
                nested.* = try self.patternOfTuple(position);
                try positions.append(self.arena, .{ .nested = nested });
                try names.appendSlice(self.arena, nested.names);
            },
            else => return self.report(
                position.span,
                "only a name can be assigned to here",
                "Unpacking assigns to names that already exist, as in `(left, right) = (right, left)`. Write `_` for a position you do not need.",
            ),
        }
    }
    return .{
        .span = left.span,
        .positions = try positions.toOwnedSlice(self.arena),
        .names = try names.toOwnedSlice(self.arena),
    };
}

const Target = struct {
    name: []const u8,
    name_span: Source.Span,
    steps: []const Ast.Step,
};

/// What can be assigned to: a name, or a place reached from a name through
/// indexing or field access, as in `grid[0][1] = 5` or `point.x = 1`.
fn assignmentTarget(self: *Parser, expression: *const Ast.Expression) Error!Target {
    var steps: std.ArrayList(Ast.Step) = .empty;
    var current = expression;
    while (true) {
        switch (current.data) {
            .index => |index| {
                try steps.append(self.arena, .{ .index = index.index });
                current = index.base;
            },
            .member => |member| {
                // `entry.0 = 1`: a tuple position can never be assigned to,
                // since there is no way to change one after it is built.
                if (member.position != null) {
                    return self.report(
                        current.span,
                        "a tuple cannot be changed in place",
                        "Build a new one, as in `pair = (1, pair.1)`.",
                    );
                }
                try steps.append(self.arena, .{ .field = .{ .name = member.name, .span = member.name_span } });
                current = member.base;
            },
            else => break,
        }
    }
    if (current.data == .call and steps.items.len > 0) {
        return self.report(
            expression.span,
            "an assignment has to start from a name, not a call",
            "Keep what the call gives in a name first, as in `const found = find()`, then assign through it, as in `found.score = 1`. When it is an object, the change reaches the same object.",
        );
    }
    if (current.data != .name) {
        return self.report(
            expression.span,
            "this cannot be assigned to",
            "Assign to a name, as in `score = 1`, or to a field or element, as in `point.x = 1` or `scores[0] = 1`.",
        );
    }
    // Collected innermost first; stored outermost first, the order they apply.
    std.mem.reverse(Ast.Step, steps.items);
    return .{
        .name = current.data.name,
        .name_span = current.span,
        .steps = try steps.toOwnedSlice(self.arena),
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
    if (self.check(.keyword_is)) return self.finishTypeTest(first);
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

    if (self.check(.keyword_is)) {
        return self.report(
            self.peek().span,
            "`is` cannot follow a comparison",
            "Put one of them in parentheses, as in `(a == b) and (value is Dog)`.",
        );
    }
    return self.node(spanning(first.span, end), .{ .comparison = .{
        .operands = try operands.toOwnedSlice(self.arena),
        .operators = try operators.toOwnedSlice(self.arena),
    } });
}

/// Section 4.4's `value is Type`. It sits with the comparisons, so `not`,
/// `and`, and `or` apply to the whole test, and like a range it does not chain.
fn finishTypeTest(self: *Parser, value: *const Ast.Expression) Error!*const Ast.Expression {
    const keyword = self.advance();
    if (self.check(.keyword_not)) {
        return self.report(
            spanning(keyword.span, self.peek().span),
            "`is not` is not how a failed type test is written",
            "Put `not` in front of the whole test, as in `not (value is Dog)`.",
        );
    }
    const target = try self.parseTypeExpression();
    if (target.question_span) |question| {
        try self.note(
            question,
            "`is` tests for a type without `?`",
            "A value that is there has a type without `?`. To ask whether it is there at all, compare it with `nothing`.",
        );
    }
    if (self.check(.keyword_is) or comparisonOperator(self.peek().kind) != null) {
        return self.report(
            self.peek().span,
            "a type test cannot be chained",
            "Put the test in parentheses, as in `(value is Dog) == expected`.",
        );
    }
    return self.node(spanning(value.span, target.span), .{ .type_test = .{ .value = value, .target = target } });
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
            .left_brace => if (self.in_control_header or !takesTrailingLambda(base))
                return base
            else
                try self.finishTrailingLambda(base),
            // Section 4.5's `?.` waits for the chains it exists to shorten:
            // with no objects yet there is nothing to reach through.
            .question_dot => return self.report(
                self.peek().span,
                "optional chaining is not available yet",
                "Check the value against `nothing` first, or give it a fallback with `.or(...)`.",
            ),
            else => return base,
        };
    }
}

fn finishCall(self: *Parser, callee: *const Ast.Expression) Error!*const Ast.Expression {
    try self.nest(self.peek().span);
    defer self.unnest();
    const saved_header = self.in_control_header;
    self.in_control_header = false;
    defer self.in_control_header = saved_header;
    _ = self.advance();

    var arguments: std.ArrayList(*const Ast.Expression) = .empty;
    var names: std.ArrayList(?Ast.Expression.Call.ArgumentName) = .empty;
    var any_named = false;
    if (!self.check(.right_paren)) {
        while (true) {
            // Section 7.3's `punctuation: "?"`. A name followed by `:` cannot
            // begin an expression, so this is never ambiguous.
            var name: ?Ast.Expression.Call.ArgumentName = null;
            // `name = value` is a habit from other languages; assignment is a
            // statement here (5.2), so it can only have meant a name.
            if (self.check(.identifier) and self.peekAfterNext().kind == .equal) {
                const written = self.peek();
                return self.reportFmt(
                    self.tokens[self.index + 1].span,
                    "a named argument is written with `:`",
                    .{},
                    try std.fmt.allocPrint(self.arena, "Write `{s}: ...` instead of `{s} = ...`.", .{ self.text(written), self.text(written) }),
                );
            }
            if (self.check(.identifier) and self.peekAfterNext().kind == .colon) {
                const token = self.advance();
                _ = self.advance();
                name = .{ .text = try self.identifier(token), .span = token.span };
                any_named = true;
            }
            try names.append(self.arena, name);
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
        .names = if (any_named) try names.toOwnedSlice(self.arena) else &.{},
    } });
}

fn finishIndex(self: *Parser, base: *const Ast.Expression) Error!*const Ast.Expression {
    try self.nest(self.peek().span);
    defer self.unnest();
    const saved_header = self.in_control_header;
    self.in_control_header = false;
    defer self.in_control_header = saved_header;
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

/// The name after a `.`, which may be a keyword.
///
/// Section 3.4 keeps keywords reserved so that "member declarations do not
/// create a second identifier grammar", and they still are: a member is
/// declared with an ordinary name. Only reaching for one accepts a keyword,
/// which is what lets section 4.5 spell its fallback `maybe.or(0)` — the
/// spelling that matches `to_int_or` — without a keyword after `.` ever being
/// able to mean anything but a member.
fn finishMember(self: *Parser, base: *const Ast.Expression) Error!*const Ast.Expression {
    _ = self.advance();
    const name = self.peek();

    // Section 8.2's `entry.0`. The lexer already splits this into `.` and a
    // whole number, because a `.` is only a decimal point when it follows one.
    if (name.kind == .int_literal) {
        _ = self.advance();
        return self.positionMember(base, self.text(name), name.span);
    }

    // `entry.0.1`, where the lexer read `0.1` as a decimal number because a
    // digit did follow the dot. Two positions were written, so two are taken.
    if (name.kind == .float_literal) {
        const written = self.text(name);
        if (std.mem.indexOfScalar(u8, written, '.')) |dot| {
            _ = self.advance();
            const outer_span: Source.Span = .{ .start = name.span.start, .end = name.span.start + @as(u32, @intCast(dot)) };
            const inner_span: Source.Span = .{ .start = outer_span.end + 1, .end = name.span.end };
            const first = try self.positionMember(base, written[0..dot], outer_span);
            return self.positionMember(first, written[dot + 1 ..], inner_span);
        }
    }

    const written: []const u8 = if (name.kind == .identifier)
        try self.identifier(name)
    else
        name.kind.keyword() orelse return self.reportFmt(
            name.span,
            "expected a property or method name after `.`, found {s}",
            .{name.kind.describe()},
            "Write the name of what to use, as in `scores.count`.",
        );
    _ = self.advance();

    return self.node(spanning(base.span, name.span), .{ .member = .{
        .base = base,
        .name = written,
        .name_span = name.span,
    } });
}

/// Section 8.2's `["Ava": 12, "Noah": 13]`, once the first key is parsed and a
/// colon has been seen.
fn finishDictionaryLiteral(
    self: *Parser,
    opening: Token,
    first_key: *const Ast.Expression,
) Error!*const Ast.Expression {
    var entries: std.ArrayList(Ast.Expression.Entry) = .empty;

    var key = first_key;
    while (true) {
        _ = self.advance(); // the `:`
        self.skipSeparators();
        try entries.append(self.arena, .{ .key = key, .value = try self.parseExpression() });
        self.skipSeparators();
        if (self.match(.comma) == null) break;
        self.skipSeparators();
        if (self.check(.right_bracket)) break; // a trailing comma

        key = try self.parseExpression();
        if (!self.check(.colon)) {
            return self.report(
                key.span,
                "this entry has no value",
                "Every entry of a dictionary is written `key: value`, and they are separated by commas.",
            );
        }
    }

    const closing = self.peek();
    if (closing.kind != .right_bracket) {
        return self.reportFmt(
            closing.span,
            "expected `]` to close this dictionary, found {s}",
            .{closing.kind.describe()},
            "Separate the entries with commas and close the dictionary with `]`.",
        );
    }
    _ = self.advance();

    return self.node(spanning(opening.span, closing.span), .{
        .dictionary_literal = try entries.toOwnedSlice(self.arena),
    });
}

/// Section 8.2's `("score", 10)`, once the first position is parsed and a comma
/// has been seen.
fn finishTupleLiteral(
    self: *Parser,
    opening: Token,
    first: *const Ast.Expression,
) Error!*const Ast.Expression {
    var positions: std.ArrayList(*const Ast.Expression) = .empty;
    try positions.append(self.arena, first);

    while (self.match(.comma)) |_| {
        self.skipSeparators();
        if (self.check(.right_paren)) break; // a trailing comma
        try positions.append(self.arena, try self.parseExpression());
        self.skipSeparators();
    }

    const closing = self.peek();
    if (closing.kind != .right_paren) {
        return self.reportFmt(
            closing.span,
            "expected `)` to close this tuple, found {s}",
            .{closing.kind.describe()},
            "Separate the positions with commas and close the tuple with `)`.",
        );
    }
    _ = self.advance();

    return self.node(spanning(opening.span, closing.span), .{
        .tuple_literal = try positions.toOwnedSlice(self.arena),
    });
}

/// Section 8.2's `(name, age)` where names are being introduced or assigned to.
/// Only names and `_` may appear, so this is not `parseExpression` with a check
/// afterwards: reporting `(a.b, c)` as "expected a name" beats reporting it as
/// a bad assignment target.
fn parsePattern(self: *Parser) Error!Ast.Pattern {
    const opening = self.advance();
    var positions: std.ArrayList(Ast.Pattern.Position) = .empty;
    var names: std.ArrayList(Ast.Pattern.Name) = .empty;

    while (true) {
        self.skipSeparators();
        const token = self.peek();
        switch (token.kind) {
            .identifier => {
                _ = self.advance();
                const name: Ast.Pattern.Name = .{ .text = try self.identifier(token), .span = token.span };
                try positions.append(self.arena, .{ .name = name });
                try names.append(self.arena, name);
            },
            .underscore => {
                _ = self.advance();
                const name: Ast.Pattern.Name = .{ .text = "_", .span = token.span };
                try positions.append(self.arena, .{ .name = name });
                try names.append(self.arena, name);
            },
            // Section 7.4: a position that is itself a tuple unpacks in place.
            .left_paren => {
                try self.nest(token.span);
                defer self.unnest();
                const nested = try self.arena.create(Ast.Pattern);
                nested.* = try self.parsePattern();
                try positions.append(self.arena, .{ .nested = nested });
                try names.appendSlice(self.arena, nested.names);
            },
            else => return self.reportFmt(
                token.span,
                "expected a name, found {s}",
                .{token.kind.describe()},
                "A tuple is unpacked into names, as in `(name, age)`. Write `_` for a position you do not need.",
            ),
        }
        self.skipSeparators();
        if (self.match(.comma) == null) break;
        self.skipSeparators();
        if (self.check(.right_paren)) break; // a trailing comma
    }

    const closing = self.peek();
    if (closing.kind != .right_paren) {
        return self.reportFmt(
            closing.span,
            "expected `)` to close these names, found {s}",
            .{closing.kind.describe()},
            "Separate the names with commas and close them with `)`.",
        );
    }
    _ = self.advance();

    if (positions.items.len < 2) {
        return self.report(
            spanning(opening.span, closing.span),
            "a tuple is unpacked into at least two names",
            "A tuple holds at least two values. Drop the parentheses to bind one name.",
        );
    }

    return .{
        .span = spanning(opening.span, closing.span),
        .positions = try positions.toOwnedSlice(self.arena),
        .names = try names.toOwnedSlice(self.arena),
    };
}

/// Whether a `(` here begins names being assigned to: a pattern whose closing
/// `)` is followed by `=`, and not by `==` or any compound operator.
fn startsPatternAssignment(self: *Parser) bool {
    if (!self.startsPattern()) return false;
    var depth: usize = 0;
    var at = self.index;
    while (at < self.tokens.len) : (at += 1) {
        switch (self.tokens[at].kind) {
            .left_paren => depth += 1,
            .right_paren => {
                depth -= 1;
                if (depth == 0) return at + 1 < self.tokens.len and self.tokens[at + 1].kind == .equal;
            },
            else => {},
        }
    }
    return false;
}

/// Whether a `(` here begins names being bound rather than an expression.
/// Only names, `_`, and commas may appear before the `)`.
fn startsPattern(self: *Parser) bool {
    if (!self.check(.left_paren)) return false;
    var at = self.index;
    var expect_name = true;
    // Whether a name has been seen since the last `(`, so `(a, b,)` with its
    // trailing comma counts, as `parsePattern` accepts it, and `()` does not.
    var any_name = false;
    while (at < self.tokens.len) : (at += 1) {
        switch (self.tokens[at].kind) {
            .doc_comment, .newline => {},
            .left_paren => {
                if (!expect_name) return false;
                any_name = false;
            },
            .identifier, .underscore => {
                if (!expect_name) return false;
                expect_name = false;
                any_name = true;
            },
            .comma => {
                if (expect_name) return false;
                expect_name = true;
            },
            .right_paren => return any_name,
            else => return false,
        }
    }
    return false;
}

/// One `.0` of a member chain, given the digits as written.
fn positionMember(
    self: *Parser,
    base: *const Ast.Expression,
    written: []const u8,
    span: Source.Span,
) Error!*const Ast.Expression {
    const position = std.fmt.parseInt(u32, written, 10) catch return self.report(
        span,
        "this tuple position is too large",
        "Positions are counted from `0`, and a tuple has at most a handful.",
    );
    return self.node(spanning(base.span, span), .{ .member = .{
        .base = base,
        .name = written,
        .name_span = span,
        .position = position,
    } });
}

/// Whether a trailing lambda may follow this expression. Only the forms that
/// name something callable, so a `{` after anything else is left alone and
/// reported where it actually goes wrong.
fn takesTrailingLambda(base: *const Ast.Expression) bool {
    return switch (base.data) {
        .name, .member, .call => true,
        else => false,
    };
}

/// Section 5.4's one exception to parenthesized calls: `numbers.each { ... }`.
/// The lambda becomes the call's final argument, so `each { ... }` and
/// `reduce(0) { ... }` are the same shape with a different number of arguments
/// before the block.
fn finishTrailingLambda(self: *Parser, base: *const Ast.Expression) Error!*const Ast.Expression {
    const lambda = try self.parseLambda();

    var arguments: std.ArrayList(*const Ast.Expression) = .empty;
    var names: []const ?Ast.Expression.Call.ArgumentName = &.{};
    const callee = if (base.data == .call) blk: {
        try arguments.appendSlice(self.arena, base.data.call.arguments);
        if (base.data.call.names.len > 0) {
            // The block has no name; `trailing` says where it goes.
            const extended = try self.arena.alloc(?Ast.Expression.Call.ArgumentName, base.data.call.names.len + 1);
            @memcpy(extended[0..base.data.call.names.len], base.data.call.names);
            extended[base.data.call.names.len] = null;
            names = extended;
        }
        break :blk base.data.call.callee;
    } else base;
    try arguments.append(self.arena, lambda);

    return self.node(spanning(base.span, lambda.span), .{ .call = .{
        .callee = callee,
        .arguments = try arguments.toOwnedSlice(self.arena),
        .names = names,
        .trailing = true,
    } });
}

/// Section 7.4's `{ value => value * 2 }`.
///
/// Section 8.2 is what makes this unambiguous: braces in expression position
/// begin a lambda and nothing else, which is exactly why collection literals
/// use brackets. So a `{` here needs no lookahead to classify.
fn parseLambda(self: *Parser) Error!*const Ast.Expression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();

    // The body is a body, whatever the statement around it was doing.
    const saved_header = self.in_control_header;
    self.in_control_header = false;
    defer self.in_control_header = saved_header;
    const saved_top_level = self.at_top_level;
    self.at_top_level = false;
    defer self.at_top_level = saved_top_level;
    const saved_self = self.self_allowed;
    if (self.self_allowed == .member) self.self_allowed = .member_lambda;
    defer self.self_allowed = saved_self;

    const header = try self.parseLambdaParameters(opening);
    const parameters = header.parameters;

    // Section 7.4: a lambda whose body is one expression produces it. That is
    // the only body written on the same line as `=>` that is not a statement,
    // so the expression is parsed first and what follows it decides: a `}` ends
    // a lambda that produces a value, and anything else was the start of a
    // statement all along.
    //
    // Whether the body is on that line is read from the source rather than from
    // a newline token, because `=>` continues the line the way any other
    // operator does and the lexer has already dropped the break after it.
    if (!self.brokeLine(header.arrow)) {
        const start = self.peek();
        const first = try self.parseExpression();
        if (self.check(.right_brace)) {
            const closing = self.advance();
            return self.node(spanning(opening.span, closing.span), .{ .lambda = .{
                .parameters = parameters,
                .body = .{ .expression = first },
            } });
        }
        return self.finishLambdaBlock(opening, parameters, try self.finishStatementFrom(start, first));
    }

    return self.finishLambdaBlock(opening, parameters, null);
}

/// The names between `{` and `=>`, each with an optional type. A lambda with no
/// parameters still writes the arrow, so `{ => do_work() }` is never mistaken
/// for something else.
fn parseLambdaParameters(self: *Parser, opening: Token) Error!LambdaHeader {
    var parameters: std.ArrayList(Ast.Expression.LambdaParameter) = .empty;
    if (self.check(.fat_arrow)) {
        return .{ .parameters = &.{}, .arrow = self.advance() };
    }

    while (true) {
        // Section 8.6's `{ (name, age) => ... }`: the one item the block
        // receives is a tuple, unpacked in the header.
        if (self.startsPattern()) {
            const pattern = try self.parsePattern();
            try parameters.append(self.arena, .{
                .name = "",
                .name_span = pattern.span,
                .annotation = null,
                .pattern = pattern,
            });
            if (self.match(.comma) == null) break;
            continue;
        }

        const name = self.peek();
        if (name.kind != .identifier and name.kind != .underscore) {
            const at = if (name.kind == .right_brace) opening.span else name.span;
            // Step over the rest of the lambda first, so its closing `}` is not
            // reported a second time as one that closes nothing.
            self.skipPastBraces();
            return self.reportFmt(
                at,
                "expected a lambda parameter, found {s}",
                .{name.kind.describe()},
                "A lambda names what it receives and then writes `=>`, as in `{ number => number * 2 }`. An empty list is written `[]`.",
            );
        }
        _ = self.advance();

        const annotation: ?Ast.TypeExpression = if (self.match(.colon) == null)
            null
        else
            try self.parseTypeExpression();

        try parameters.append(self.arena, .{
            .name = try self.identifier(name),
            .name_span = name.span,
            .annotation = annotation,
        });
        if (self.match(.comma) == null) break;
    }

    const arrow = self.match(.fat_arrow) orelse {
        const found = self.peek();
        self.skipPastBraces();
        return self.reportFmt(
            found.span,
            "expected `=>` after this lambda's parameters, found {s}",
            .{found.kind.describe()},
            "A lambda separates what it receives from what it does with `=>`, as in `{ number => number * 2 }`.",
        );
    };
    return .{ .parameters = try parameters.toOwnedSlice(self.arena), .arrow = arrow };
}

const LambdaHeader = struct {
    parameters: []const Ast.Expression.LambdaParameter,
    arrow: Token,
};

/// Whether what follows the `{` just consumed is a lambda's parameter list.
/// `=>` appears nowhere else in the grammar, so finding one before the line
/// ends settles it.
fn startsLambdaHeader(self: *Parser) bool {
    var at = self.index;
    var seen: u32 = 0;
    while (seen < 16) : (seen += 1) {
        switch (self.tokens[at].kind) {
            .fat_arrow => return true,
            .newline, .right_brace, .left_brace, .eof => return false,
            else => {},
        }
        at += 1;
    }
    return false;
}

/// Consumes the rest of a brace-delimited body whose opening `{` is already
/// consumed, up to and including the `}` that closes it. Without this,
/// statement recovery would resume inside it and report its closing brace as a
/// stray one.
fn skipPastBraces(self: *Parser) void {
    var depth: u32 = 1;
    while (true) {
        switch (self.peek().kind) {
            .eof => return,
            .left_brace => depth += 1,
            .right_brace => {
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

/// Whether the source breaks the line between `token` and whatever comes next.
fn brokeLine(self: *Parser, token: Token) bool {
    const between = self.source.text[token.span.end..self.peek().span.start];
    return std.mem.indexOfScalar(u8, between, '\n') != null;
}

/// A lambda whose body is statements rather than one expression. Its `{` is
/// already consumed, so this closes what `parseLambda` opened. `first` is the
/// statement already parsed on the `=>` line, when there was one.
fn finishLambdaBlock(
    self: *Parser,
    opening: Token,
    parameters: []const Ast.Expression.LambdaParameter,
    first: ?Ast.Statement,
) Error!*const Ast.Expression {
    var statements: std.ArrayList(Ast.Statement) = .empty;
    if (first) |statement| try statements.append(self.arena, statement);
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
            "this lambda is never closed",
            "Add the closing `}` that ends it.",
        );
    }
    _ = self.advance();

    const span = spanning(opening.span, closing.span);
    return self.node(span, .{ .lambda = .{
        .parameters = parameters,
        .body = .{ .block = .{
            .span = span,
            .statements = try statements.toOwnedSlice(self.arena),
        } },
    } });
}

/// Section 8.2's list literal. A trailing comma is allowed, which keeps a
/// literal written one element per line uniform. Newlines inside the brackets
/// never end the statement, which the lexer already arranges.
fn parseListLiteral(self: *Parser) Error!*const Ast.Expression {
    const opening = self.advance();
    try self.nest(opening.span);
    defer self.unnest();
    const saved_header = self.in_control_header;
    self.in_control_header = false;
    defer self.in_control_header = saved_header;

    var elements: std.ArrayList(*const Ast.Expression) = .empty;
    while (!self.check(.right_bracket)) {
        self.skipSeparators();
        if (self.check(.right_bracket)) break; // a trailing comma
        const first = try self.parseExpression();

        // Section 8.2: a `key: value` entry makes this a dictionary literal.
        if (self.check(.colon)) return self.finishDictionaryLiteral(opening, first);

        try elements.append(self.arena, first);
        self.skipSeparators();
        if (self.match(.comma) == null) break;
    }
    self.skipSeparators();

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
        .left_brace => return self.parseLambda(),
        .keyword_case => {
            const parsed = try self.parseCase();
            const span = spanning(parsed.keyword_span, self.tokens[self.index - 1].span);
            if (!parsed.producesValue()) {
                return self.report(
                    span,
                    "a `case` used as a value gives each `when` a value with `then`",
                    "Write `when ... then value` for each arm, and `else then value`, or use the `case` as a statement on its own line.",
                );
            }
            return self.node(span, .{ .case_expression = parsed });
        },
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
        // Section 10.2's `self`, which is a keyword and so can never collide
        // with a name the program declares. Every later pass sees it as the
        // name of the value under construction.
        .keyword_self => {
            _ = self.advance();
            switch (self.self_allowed) {
                .member, .class_member => {},
                .type_member => try self.note(
                    token.span,
                    "a type-level member has no `self`",
                    "It belongs to the type, not to any one value. Take the value as a parameter, or leave out the type name to make this an instance member.",
                ),
                .member_lambda => try self.note(
                    token.span,
                    "a block cannot use `self` yet",
                    "Read what the block needs into a local first, as in `const x = self.x`, and use that inside the block.",
                ),
                .member_nested => try self.note(
                    token.span,
                    "a nested function cannot use `self` yet",
                    "Read what the function needs into a local first, as in `const x = self.x`, and use that inside the function.",
                ),
                .nowhere => try self.note(
                    token.span,
                    "`self` is only available inside a constructor or a method",
                    "Declare this function inside the struct or class to make it a method, or pass the value in as a parameter.",
                ),
            }
            return self.node(token.span, .{ .name = "self" });
        },
        // Section 10.7's `super`, which reaches the base class's version of a
        // member, or its constructor. It is seen as a name, like `self`.
        .keyword_super => {
            _ = self.advance();
            if (!self.check(.dot) and !self.check(.left_paren)) {
                return self.report(
                    token.span,
                    "`super` is not a value on its own",
                    "Reach the base class's version of a member, as in `super.speak()`, or call its constructor with `super(...)`. Use `self` for the object itself.",
                );
            }
            switch (self.self_allowed) {
                .class_member => if (!self.has_base) try self.reportFmtNote(
                    token.span,
                    "`{s}` has no base class, so there is no `super`",
                    .{self.type_name},
                    try std.fmt.allocPrint(self.arena, "Give it one with `extends`, as in `class {s} extends Base`, or reach its own members through `self`.", .{self.type_name}),
                ),
                .member, .member_lambda, .member_nested => if (self.in_trait) try self.note(
                    token.span,
                    "a trait has no base class, so there is no `super`",
                    "To run the default of a trait this one builds on, write `Trait.name(self)`.",
                ) else try self.note(
                    token.span,
                    "a struct has no base class, so there is no `super`",
                    "Structs do not inherit. Reach the struct's own members through `self`.",
                ),
                .type_member => try self.note(
                    token.span,
                    "a type-level member has no `super`",
                    "It belongs to the type, not to any one object, so there is no base class's version of it to reach.",
                ),
                .nowhere => try self.note(
                    token.span,
                    "`super` is only available inside a class that extends another",
                    "Inside a subclass's method, `super.name` reaches the base class's version of a member.",
                ),
            }
            return self.node(token.span, .{ .name = "super" });
        },
        .left_paren => {
            try self.nest(token.span);
            defer self.unnest();
            const saved_header = self.in_control_header;
            self.in_control_header = false;
            defer self.in_control_header = saved_header;
            _ = self.advance();
            if (self.check(.right_paren)) {
                return self.report(
                    spanning(token.span, self.peek().span),
                    "`()` is not a value",
                    "A tuple holds at least two values. A function with no result already uses `Nothing`.",
                );
            }

            const inner = try self.parseExpression();

            // A second expression makes it section 8.2's tuple. One, with or
            // without a trailing comma, stays a grouped expression: a trailing
            // comma never changes an expression's type.
            if (self.check(.comma) and self.peekAfterNext().kind != .right_paren) {
                return self.finishTupleLiteral(token, inner);
            }
            _ = self.match(.comma);

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
