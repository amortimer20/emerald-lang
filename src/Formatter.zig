//! The canonical formatter (section 18.3): `Formatter.print` turns a parsed
//! file back into Emerald source in the one settled style, and `emerald.zig`'s
//! `formatProject` is what `emerald format` and format-on-save both call.
//!
//! Section 18.3 requires the output to be comment-preserving, but `Lexer.zig`
//! discards ordinary `#` and `#[ ... ]#` comments entirely (they never become
//! tokens) and `Parser.zig` discards `.doc_comment` tokens without attaching
//! them to any AST node. Rather than changing either — both are on the
//! interpreter's hot path and neither needs to change for anything else this
//! formatter does — `collectTrivia` recovers every comment and blank-line run
//! by re-scanning the byte gaps between the tokens the lexer already produced.
//! Every such gap is provably nothing but spacing, newlines, and comments:
//! string and interpolation content always lives inside a token's own span
//! (`string_start`/`string_middle`/`string_end`), never in the gap between two
//! tokens, so a small dedicated scanner mirroring `Lexer.lexComment`'s
//! recognition rules is all a gap ever needs.
//!
//! The printer is a recursive-descent walk of the parsed `Ast.Program`, the
//! same tree the checker and interpreter walk, reusing two of its fields that
//! exist specifically for this: `Ast.If.trailing` and `Ast.Else.chained` vs
//! `.block` keep the trailing-guard and `else if` forms distinct from the
//! block forms they would otherwise be indistinguishable from once parsed, so
//! the printer recovers the surface form without re-deriving it. A single
//! monotonic cursor into the flat, source-ordered trivia list is advanced as
//! the printer visits each statement, member, or case arm in source order, so
//! a comment or blank line is emitted exactly once, wherever it belongs,
//! regardless of how deeply the construct around it is nested.
//!
//! Two deliberate simplifications keep this first slice small. First, line
//! breaks the author already chose inside one statement or expression are
//! preserved rather than reflowed to a canonical width — this is a normalizer
//! in the manner of gofmt, not a full pretty-printing engine, and no line
//! width is invented since none is settled anywhere in the rewrite context.
//! `spansMultipleLines` is the one primitive this needs: whether a call's
//! arguments, or a list, dictionary, or tuple literal's elements, already
//! contain a newline in the source decides one-line versus one-item-per-line
//! layout, uniformly, with no per-kind special casing. Second, every string
//! and interpolation literal is copied verbatim from its source span rather
//! than re-derived from the parsed, escape-cooked `Ast` value. This is what
//! lets a triple-quoted string's written indentation, and code inside `#{
//! ... }`, survive untouched, at the cost of not reformatting code written
//! inside an interpolation — an acceptable gap for a first slice, since
//! interpolated expressions are almost always short.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

/// One piece of source layout the lexer's token stream does not itself carry.
/// `span` is the comment's own text for the three comment kinds; for
/// `blank_line` it is a zero-width marker positioned where the blank run was
/// found, only so it sorts correctly against everything else.
pub const Trivia = struct {
    kind: enum { blank_line, line_comment, block_comment, doc_comment },
    span: Source.Span,
};

/// Recovers every comment and blank-line run in `source`, in source order.
/// `tokens` is the full stream `Lexer.tokenize` produced, `.doc_comment`
/// tokens included: the gap before each token is scanned, and a `.doc_comment`
/// token itself becomes a `Trivia` entry from its own span.
pub fn collectTrivia(gpa: std.mem.Allocator, source: *const Source, tokens: []const Token) ![]const Trivia {
    var out: std.ArrayList(Trivia) = .empty;
    errdefer out.deinit(gpa);

    var prev_end: u32 = 0;
    // Carried across both gaps and `.newline` tokens: a statement's own
    // terminating newline is a real token, not part of any gap, so a blank
    // line right after one would be undercounted by one if each gap reset
    // this on its own.
    var newlines: u32 = 0;
    for (tokens) |token| {
        try scanGap(gpa, &out, source.text, prev_end, token.span.start, &newlines);
        switch (token.kind) {
            .newline => newlines += 1,
            .doc_comment => {
                if (newlines > 1) try out.append(gpa, .{ .kind = .blank_line, .span = .{ .start = token.span.start, .end = token.span.start } });
                newlines = 0;
                try out.append(gpa, .{ .kind = .doc_comment, .span = token.span });
            },
            else => {
                if (newlines > 1) try out.append(gpa, .{ .kind = .blank_line, .span = .{ .start = token.span.start, .end = token.span.start } });
                newlines = 0;
            },
        }
        prev_end = token.span.end;
    }
    return out.toOwnedSlice(gpa);
}

/// Scans `text[start..end]`, a gap between two tokens (or before the first
/// one) that a successful tokenize guarantees holds only spacing, blank
/// lines, and comments — never string or interpolation content, which always
/// lives inside a token's own span instead. `newlines` is shared with the
/// caller's own count of consecutive blank-run newlines, since a `.newline`
/// token can sit in the middle of one run; a `.blank_line` marker is recorded,
/// by the caller, once it knows the run cannot continue any further.
fn scanGap(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Trivia),
    text: []const u8,
    start: u32,
    end: u32,
    newlines: *u32,
) !void {
    var i = start;
    while (i < end) {
        switch (text[i]) {
            ' ', '\t', '\r' => i += 1,
            '\n' => {
                newlines.* += 1;
                i += 1;
            },
            '#' => {
                if (newlines.* > 1) try out.append(gpa, .{ .kind = .blank_line, .span = .{ .start = i, .end = i } });
                newlines.* = 0;
                if (i + 1 < end and text[i + 1] == '[') {
                    const comment_start = i;
                    i += 2;
                    var depth: u32 = 1;
                    while (i < end and depth > 0) {
                        if (i + 1 < end and text[i] == '#' and text[i + 1] == '[') {
                            depth += 1;
                            i += 2;
                        } else if (i + 1 < end and text[i] == ']' and text[i + 1] == '#') {
                            depth -= 1;
                            i += 2;
                        } else {
                            i += 1;
                        }
                    }
                    try out.append(gpa, .{ .kind = .block_comment, .span = .{ .start = comment_start, .end = i } });
                } else {
                    const comment_start = i;
                    while (i < end and text[i] != '\n') i += 1;
                    try out.append(gpa, .{ .kind = .line_comment, .span = .{ .start = comment_start, .end = i } });
                }
            },
            // A successful tokenize guarantees a gap is nothing else: string
            // and interpolation content always lives inside a token's span.
            else => unreachable,
        }
    }
}

/// Formats one already-parsed file. `allocator` is expected to be an arena (or
/// otherwise not individually freed): the result, and everything built while
/// producing it, come from it.
pub fn print(
    allocator: std.mem.Allocator,
    source: *const Source,
    tokens: []const Token,
    program: Ast.Program,
) ![]const u8 {
    const trivia = try collectTrivia(allocator, source, tokens);
    defer allocator.free(trivia);
    var printer: Printer = .{ .gpa = allocator, .source = source, .trivia = trivia };
    try printer.printProgram(program);

    // Exactly one trailing newline, matching §3.1's formatter-output rule,
    // regardless of what trailing blank lines or comments left behind.
    while (printer.out.items.len > 0 and printer.out.items[printer.out.items.len - 1] == '\n') {
        _ = printer.out.pop();
    }
    try printer.out.append(allocator, '\n');
    return printer.out.toOwnedSlice(allocator);
}

const PrintError = std.mem.Allocator.Error;

const Printer = struct {
    gpa: std.mem.Allocator,
    source: *const Source,
    trivia: []const Trivia,
    trivia_cursor: usize = 0,
    out: std.ArrayList(u8) = .empty,
    indent: u32 = 0,

    // Primitives.

    fn write(self: *Printer, bytes: []const u8) PrintError!void {
        try self.out.appendSlice(self.gpa, bytes);
    }

    fn writeSpan(self: *Printer, span: Source.Span) PrintError!void {
        try self.write(self.source.text[span.start..span.end]);
    }

    fn writeIndent(self: *Printer) PrintError!void {
        try self.out.appendNTimes(self.gpa, ' ', self.indent * 4);
    }

    fn writeInt(self: *Printer, value: u32) PrintError!void {
        var buffer: [10]u8 = undefined;
        const written = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try self.write(written);
    }

    /// Whether the source text spanning `[start, end)` already contains a
    /// newline.
    fn spansMultipleLines(self: *Printer, start: u32, end: u32) bool {
        return std.mem.indexOfScalar(u8, self.source.text[start..end], '\n') != null;
    }

    /// The test that decides one-line versus one-item-per-line layout for
    /// every delimited list, so the author's own choice survives: whether any
    /// two adjacent expressions were already separated by a newline, checking
    /// only the gaps between them rather than each expression's own span, so
    /// one argument that happens to be a multi-line string or block does not
    /// itself force the list around it onto multiple lines.
    fn exprsSpanMultipleLines(self: *Printer, items: []const *const Ast.Expression) bool {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            if (self.spansMultipleLines(items[i - 1].span.end, items[i].span.start)) return true;
        }
        return false;
    }

    /// Emits every trivia item positioned before `before`, in order: a blank
    /// output line for each run (collapsed to exactly one regardless of how
    /// many blank source lines it was), and each comment verbatim at the
    /// current indent. Returns whether a blank-line run was seen but not yet
    /// emitted (because nothing followed it before `before`) — the caller
    /// decides whether that belongs before whatever it prints next, which is
    /// what keeps a block from starting or ending with a blank line.
    fn flushTrivia(self: *Printer, before: u32) PrintError!bool {
        var pending_blank = false;
        while (self.trivia_cursor < self.trivia.len and self.trivia[self.trivia_cursor].span.start <= before) {
            const item = self.trivia[self.trivia_cursor];
            self.trivia_cursor += 1;
            switch (item.kind) {
                .blank_line => pending_blank = true,
                .line_comment, .doc_comment, .block_comment => {
                    if (pending_blank) {
                        try self.write("\n");
                        pending_blank = false;
                    }
                    try self.writeIndent();
                    try self.writeSpan(item.span);
                    try self.write("\n");
                },
            }
        }
        return pending_blank;
    }

    /// A comment written on the same source line as whatever just ended at
    /// `after` — `print(score) # 14` — stays on that line rather than
    /// waiting to be flushed as a later statement's leading trivia, which
    /// would otherwise strand it on its own line before something it was
    /// never written to describe.
    fn printTrailingComment(self: *Printer, after: u32) PrintError!void {
        if (self.trivia_cursor >= self.trivia.len) return;
        const item = self.trivia[self.trivia_cursor];
        if (item.kind == .blank_line or self.spansMultipleLines(after, item.span.start)) return;
        self.trivia_cursor += 1;
        try self.write(" ");
        try self.writeSpan(item.span);
    }

    // Top level.

    const TopItem = union(enum) {
        statement: Ast.Statement,
        using: Ast.Using,

        fn start(self: TopItem) u32 {
            return switch (self) {
                .statement => |s| s.span.start,
                .using => |u| u.span.start,
            };
        }

        fn end(self: TopItem) u32 {
            return switch (self) {
                .statement => |s| s.span.end,
                .using => |u| u.span.end,
            };
        }
    };

    fn topItemLessThan(_: void, a: TopItem, b: TopItem) bool {
        return a.start() < b.start();
    }

    /// `using` declarations are file-local and kept apart from the
    /// statements by the parser (§14.2), so they are merged back into one
    /// source-ordered sequence here rather than always printed first.
    fn printProgram(self: *Printer, program: Ast.Program) PrintError!void {
        var items: std.ArrayList(TopItem) = .empty;
        defer items.deinit(self.gpa);
        for (program.statements) |statement| try items.append(self.gpa, .{ .statement = statement });
        for (program.using) |using| try items.append(self.gpa, .{ .using = using });
        std.mem.sort(TopItem, items.items, {}, topItemLessThan);

        const mark = self.out.items.len;
        for (items.items) |item| {
            const pending_blank = try self.flushTrivia(item.start());
            if (pending_blank and self.out.items.len != mark) try self.write("\n");
            try self.writeIndent();
            switch (item) {
                .statement => |statement| try self.printStatement(statement),
                .using => |using| try self.printUsing(using),
            }
            try self.printTrailingComment(item.end());
            try self.write("\n");
        }
        _ = try self.flushTrivia(@intCast(self.source.text.len));
    }

    fn printUsing(self: *Printer, using: Ast.Using) PrintError!void {
        try self.write("using ");
        if (using.alias.len > 0) {
            try self.write(using.alias);
            try self.write(" = ");
        }
        for (using.path, 0..) |segment, i| {
            if (i > 0) try self.write(".");
            try self.write(segment);
        }
    }

    // Blocks.

    fn printBlock(self: *Printer, block: Ast.Block) PrintError!void {
        try self.write("{\n");
        try self.printStatementsIndented(block.statements, block.span.end);
        try self.writeIndent();
        try self.write("}");
    }

    fn printStatementsIndented(self: *Printer, statements: []const Ast.Statement, end: u32) PrintError!void {
        self.indent += 1;
        const mark = self.out.items.len;
        for (statements) |statement| {
            const pending_blank = try self.flushTrivia(statement.span.start);
            if (pending_blank and self.out.items.len != mark) try self.write("\n");
            try self.writeIndent();
            try self.printStatement(statement);
            try self.printTrailingComment(statement.span.end);
            try self.write("\n");
        }
        _ = try self.flushTrivia(end);
        self.indent -= 1;
    }

    // Statements.

    fn printStatement(self: *Printer, statement: Ast.Statement) PrintError!void {
        switch (statement.data) {
            .expression => |e| try self.printExpr(e),
            .declaration => |d| try self.printDeclaration(d),
            .assignment => |a| try self.printAssignment(a),
            .conditional => |c| try self.printIf(c),
            .while_loop => |w| try self.printWhile(w),
            .for_loop => |f| try self.printFor(f),
            .break_statement => try self.write("break"),
            .continue_statement => try self.write("continue"),
            .function_declaration => |f| try self.printFunctionDeclaration(f, false),
            .struct_declaration => |s| try self.printStructDeclaration(s, statement.span.end),
            .return_statement => |r| {
                try self.write("return");
                if (r.value) |value| {
                    try self.write(" ");
                    try self.printExpr(value);
                }
            },
            .raise_statement => |r| {
                try self.write("raise");
                if (r.value) |value| {
                    try self.write(" ");
                    try self.printExpr(value);
                }
            },
            .try_statement => |t| try self.printTry(t),
            .assert_statement => |a| {
                try self.write("assert ");
                try self.printExpr(a.condition);
                if (a.message) |message| {
                    try self.write(", ");
                    try self.printExpr(message);
                }
            },
            .destructuring => |d| try self.printDestructuring(d),
            .destructuring_assignment => |d| try self.printDestructuringAssignment(d),
            .case_statement => |c| try self.printCase(c, statement.span.end),
        }
    }

    fn printDeclaration(self: *Printer, d: Ast.Declaration) PrintError!void {
        try self.write(if (d.mutable) "var " else "const ");
        try self.write(d.name);
        if (d.annotation) |a| {
            try self.write(": ");
            try self.printType(a);
        }
        if (d.initializer) |init| {
            try self.write(" = ");
            try self.printExpr(init);
        }
    }

    fn printAssignment(self: *Printer, a: Ast.Assignment) PrintError!void {
        try self.write(a.name);
        for (a.steps) |step| {
            switch (step) {
                .index => |index| {
                    try self.write("[");
                    try self.printExpr(index);
                    try self.write("]");
                },
                .field => |field| {
                    try self.write(".");
                    try self.write(field.name);
                },
            }
        }
        try self.write(" ");
        if (a.operation) |operation| {
            try self.write(operation.lexeme());
            try self.write("=");
        } else {
            try self.write("=");
        }
        try self.write(" ");
        try self.printExpr(a.value);
    }

    fn printIf(self: *Printer, node: Ast.If) PrintError!void {
        if (node.trailing) {
            // §6.2's trailing guard: `then_block` holds the one statement it
            // guards, and there is no `else`.
            try self.printStatement(node.then_block.statements[0]);
            try self.write(" if ");
            try self.printExpr(node.condition);
            return;
        }

        try self.write("if ");
        try self.printHeaderExpr(node.condition);
        try self.write(" ");
        try self.printBlock(node.then_block);

        if (node.otherwise) |otherwise| {
            try self.write("\n");
            try self.writeIndent();
            try self.write("else ");
            switch (otherwise) {
                .block => |block| try self.printBlock(block),
                .chained => |stmt| try self.printIf(stmt.data.conditional),
            }
        }
    }

    fn printWhile(self: *Printer, w: Ast.While) PrintError!void {
        try self.write("while ");
        try self.printHeaderExpr(w.condition);
        try self.write(" ");
        try self.printBlock(w.body);
    }

    fn printFor(self: *Printer, f: Ast.For) PrintError!void {
        try self.write("for ");
        if (f.pattern) |pattern| try self.printPattern(pattern) else try self.write(f.name);
        try self.write(" in ");
        try self.printHeaderExpr(f.iterable);
        try self.write(" ");
        try self.printBlock(f.body);
    }

    /// The condition of `if`/`while`, and the iterable of `for`, are parsed
    /// with `Parser.in_control_header` set, so the `{` right after a call
    /// there always opens the statement's body rather than the call's
    /// trailing block (7.4) — a bare, unparenthesized trailing-block call is
    /// therefore never valid directly in one of these three positions, and
    /// reading it back would fail exactly where the body was meant to begin.
    /// Any bracket or parenthesis reopens the possibility beneath it, so only
    /// a header expression that reaches one *without* first crossing into
    /// one needs wrapping; `headerNeedsParens` follows exactly the set of
    /// nodes that sit bare in that position.
    fn printHeaderExpr(self: *Printer, expr: *const Ast.Expression) PrintError!void {
        if (headerNeedsParens(expr)) {
            try self.write("(");
            try self.printExpr(expr);
            try self.write(")");
        } else {
            try self.printExpr(expr);
        }
    }

    fn headerNeedsParens(expr: *const Ast.Expression) bool {
        return switch (expr.data) {
            .call => |c| c.trailing or headerNeedsParens(c.callee),
            .binary => |b| headerNeedsParens(b.left) or headerNeedsParens(b.right),
            .logical => |l| headerNeedsParens(l.left) or headerNeedsParens(l.right),
            .unary => |u| headerNeedsParens(u.operand),
            .range => |r| headerNeedsParens(r.start) or headerNeedsParens(r.end),
            .type_test => |t| headerNeedsParens(t.value),
            .member => |m| headerNeedsParens(m.base),
            .index => |i| headerNeedsParens(i.base),
            .comparison => |c| {
                for (c.operands) |operand| if (headerNeedsParens(operand)) return true;
                return false;
            },
            // Every other kind is either a leaf or already bracketed
            // (a list/dictionary/tuple literal, a lambda's own body, a
            // call's ordinary parenthesized arguments): none of them can
            // put an unbracketed `{` right where the header ends.
            else => false,
        };
    }

    fn printTry(self: *Printer, t: Ast.Try) PrintError!void {
        try self.write("try ");
        try self.printBlock(t.body);
        for (t.catches) |c| {
            try self.write("\n");
            try self.writeIndent();
            try self.write("catch ");
            try self.write(c.name);
            if (c.annotation) |a| {
                try self.write(": ");
                try self.printType(a);
            }
            try self.write(" ");
            try self.printBlock(c.body);
        }
        if (t.finally_block) |finally_block| {
            try self.write("\n");
            try self.writeIndent();
            try self.write("finally ");
            try self.printBlock(finally_block);
        }
    }

    fn printDestructuring(self: *Printer, d: Ast.Destructuring) PrintError!void {
        try self.write(if (d.mutable) "var " else "const ");
        try self.printPattern(d.pattern);
        if (d.annotation) |a| {
            try self.write(": ");
            try self.printType(a);
        }
        try self.write(" = ");
        try self.printExpr(d.initializer);
    }

    fn printDestructuringAssignment(self: *Printer, d: Ast.DestructuringAssignment) PrintError!void {
        try self.printPattern(d.pattern);
        try self.write(" = ");
        try self.printExpr(d.value);
    }

    fn printPattern(self: *Printer, pattern: Ast.Pattern) PrintError!void {
        try self.write("(");
        for (pattern.positions, 0..) |position, i| {
            if (i > 0) try self.write(", ");
            switch (position) {
                .name => |name| try self.write(name.text),
                .nested => |nested| try self.printPattern(nested.*),
            }
        }
        try self.write(")");
    }

    // `case`, shared between the statement and expression forms (§6.3).

    fn printCase(self: *Printer, case: *const Ast.Case, end: u32) PrintError!void {
        try self.write("case");
        if (case.subject) |subject| {
            try self.write(" ");
            // The subject sits in exactly the same position as an `if`'s
            // condition: a `{` right after it opens the case's first arm,
            // not a trailing block (see `printHeaderExpr`).
            try self.printHeaderExpr(subject);
        }
        try self.write(" {\n");
        self.indent += 1;

        const mark = self.out.items.len;
        for (case.arms) |arm| {
            const pending_blank = try self.flushTrivia(arm.when_span.start);
            if (pending_blank and self.out.items.len != mark) try self.write("\n");
            try self.writeIndent();
            try self.write("when ");
            for (arm.alternatives, 0..) |alternative, i| {
                if (i > 0) try self.write(", ");
                try self.printExpr(alternative);
            }
            try self.printCaseBody(arm.body);
            try self.printTrailingComment(caseBodyEnd(arm.body));
            try self.write("\n");
        }

        if (case.otherwise) |otherwise| {
            const pending_blank = try self.flushTrivia(case.else_span.?.start);
            if (pending_blank and self.out.items.len != mark) try self.write("\n");
            try self.writeIndent();
            try self.write("else");
            try self.printCaseBody(otherwise);
            try self.printTrailingComment(caseBodyEnd(otherwise));
            try self.write("\n");
        }

        _ = try self.flushTrivia(end);
        self.indent -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    fn printCaseBody(self: *Printer, body: Ast.Case.Body) PrintError!void {
        switch (body) {
            .block => |block| {
                try self.write(" ");
                try self.printBlock(block);
            },
            .value => |value| {
                try self.write(" then ");
                try self.printExpr(value);
            },
        }
    }

    fn caseBodyEnd(body: Ast.Case.Body) u32 {
        return switch (body) {
            .block => |block| block.span.end,
            .value => |value| value.span.end,
        };
    }

    // Struct, class, trait, and enum declarations.

    /// One member of a type body. The parser groups members by kind
    /// (`StructDeclaration.fields`, `.methods`, and so on), so they are
    /// merged back into source order here, exactly as `TopItem` does for a
    /// file's statements and `using` declarations.
    const Member = union(enum) {
        field: Ast.StructDeclaration.Field,
        constructor: Ast.StructDeclaration.Constructor,
        method: Ast.FunctionDeclaration,
        property: Ast.StructDeclaration.Property,
        type_function: Ast.StructDeclaration.TypeFunction,
        type_field: Ast.StructDeclaration.TypeField,

        fn start(self: Member) u32 {
            return switch (self) {
                .field => |f| f.name_span.start,
                .constructor => |c| c.keyword_span.start,
                .method => |m| m.name_span.start,
                .property => |p| p.name_span.start,
                .type_function => |t| t.declaration.name_span.start,
                .type_field => |t| t.name_span.start,
            };
        }

        fn end(self: Member) u32 {
            return switch (self) {
                .field => |f| if (f.default) |d| d.span.end else f.annotation.span.end,
                .constructor => |c| c.body.span.end,
                .method => |m| if (m.abstract_span == null) m.body.span.end else if (m.return_annotation) |r| r.span.end else m.name_span.end,
                .property => |p| if (p.setter) |setter| setter.body.span.end else if (p.getter.abstract_span == null) p.getter.body.span.end else p.annotation.span.end,
                .type_function => |t| t.declaration.body.span.end,
                .type_field => |t| if (t.enum_value != null) t.name_span.end else t.initializer.span.end,
            };
        }
    };

    fn memberLessThan(_: void, a: Member, b: Member) bool {
        return a.start() < b.start();
    }

    fn printStructDeclaration(self: *Printer, s: Ast.StructDeclaration, end: u32) PrintError!void {
        if (s.abstract_span != null) {
            try self.write("@abstract\n");
            try self.writeIndent();
        }
        try self.write(s.keyword());
        try self.write(" ");
        try self.write(s.name);
        if (s.base) |base| {
            try self.write(" extends ");
            try self.printType(base);
        }
        if (s.traits.len > 0) {
            try self.write(" with ");
            for (s.traits, 0..) |trait, i| {
                if (i > 0) try self.write(", ");
                try self.printType(trait);
            }
        }
        try self.write(" {\n");

        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(self.gpa);
        for (s.fields) |f| try members.append(self.gpa, .{ .field = f });
        if (s.constructor) |c| try members.append(self.gpa, .{ .constructor = c });
        for (s.methods) |m| try members.append(self.gpa, .{ .method = m });
        for (s.properties) |p| try members.append(self.gpa, .{ .property = p });
        for (s.type_functions) |t| try members.append(self.gpa, .{ .type_function = t });
        for (s.type_fields) |t| try members.append(self.gpa, .{ .type_field = t });
        std.mem.sort(Member, members.items, {}, memberLessThan);

        self.indent += 1;
        const mark = self.out.items.len;
        for (members.items) |member| {
            const pending_blank = try self.flushTrivia(member.start());
            if (pending_blank and self.out.items.len != mark) try self.write("\n");
            try self.writeIndent();
            switch (member) {
                .field => |f| try self.printField(f),
                .constructor => |c| try self.printConstructor(c),
                .method => |m| try self.printFunctionDeclaration(m, s.trait),
                .property => |p| try self.printProperty(p),
                .type_function => |t| try self.printFunctionDeclaration(t.declaration, s.trait),
                .type_field => |t| try self.printTypeField(t, s.name),
            }
            try self.printTrailingComment(member.end());
            try self.write("\n");
        }
        _ = try self.flushTrivia(end);
        self.indent -= 1;

        try self.writeIndent();
        try self.write("}");
    }

    fn printField(self: *Printer, f: Ast.StructDeclaration.Field) PrintError!void {
        try self.write(if (f.mutable) "var " else "const ");
        try self.write(f.name);
        try self.write(": ");
        try self.printType(f.annotation);
        if (f.default) |default| {
            try self.write(" = ");
            try self.printExpr(default);
        }
    }

    fn printConstructor(self: *Printer, c: Ast.StructDeclaration.Constructor) PrintError!void {
        try self.write("constructor(");
        try self.printParameters(c.parameters);
        try self.write(") ");
        try self.printBlock(c.body);
    }

    /// `in_trait` tells a body-less method's `abstract_span` apart from a
    /// real `@abstract` annotation: the parser reuses that field's presence
    /// as how a trait's requirement (no body) is represented, and a trait's
    /// requirement is written with no annotation at all. Either way, a null
    /// body prints no block, since that is what a requirement or an abstract
    /// method (10.7, 11.1) both are.
    fn printFunctionDeclaration(self: *Printer, f: Ast.FunctionDeclaration, in_trait: bool) PrintError!void {
        if (f.test_span != null) {
            try self.write("@test\n");
            try self.writeIndent();
        }
        if (f.override_span != null) {
            try self.write("@override\n");
            try self.writeIndent();
        }
        if (f.abstract_span != null and !in_trait) {
            try self.write("@abstract\n");
            try self.writeIndent();
        }
        try self.write("func ");
        try self.write(f.name);
        try self.write("(");
        try self.printParameters(f.parameters);
        try self.write(")");
        if (f.return_annotation) |r| {
            try self.write(": ");
            try self.printType(r);
        }
        if (f.abstract_span == null) {
            try self.write(" ");
            try self.printBlock(f.body);
        }
    }

    /// Parameter lists are always printed on one line. Every example in the
    /// language keeps them short enough that this has not needed the same
    /// line-preserving treatment call arguments and literals get; revisit if
    /// a real signature needs to wrap.
    fn printParameters(self: *Printer, parameters: []const Ast.Parameter) PrintError!void {
        for (parameters, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.write(p.name);
            try self.write(": ");
            try self.printType(p.annotation);
            if (p.default) |default| {
                try self.write(" = ");
                try self.printExpr(default);
            }
        }
    }

    fn printProperty(self: *Printer, p: Ast.StructDeclaration.Property) PrintError!void {
        if (p.override_span != null) {
            try self.write("@override\n");
            try self.writeIndent();
        }
        try self.write(if (p.mutable) "var " else "const ");
        try self.write(p.name);
        try self.write(": ");
        try self.printType(p.annotation);

        // A trait's requirement property (10.5/11.1) has no body at all.
        if (p.getter.abstract_span != null) return;

        try self.write(" ");
        if (!p.mutable) {
            try self.printBlock(p.getter.body);
            return;
        }

        try self.write("{\n");
        self.indent += 1;
        try self.writeIndent();
        try self.write("get ");
        try self.printBlock(p.getter.body);
        try self.write("\n");
        if (p.setter) |setter| {
            try self.writeIndent();
            try self.write("set ");
            try self.printBlock(setter.body);
            try self.write("\n");
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    /// `struct_name` is the enclosing type's name: a type-level field's own
    /// `name` is only the member part (10.4), the same way a struct field's
    /// is, so the qualified form has to be rebuilt here. An enum value
    /// (section 12's values are type-level `const` fields under the hood)
    /// prints as its bare name instead, with no `var`/`const` or initializer.
    fn printTypeField(self: *Printer, t: Ast.StructDeclaration.TypeField, struct_name: []const u8) PrintError!void {
        if (t.enum_value != null) {
            try self.write(t.name);
            return;
        }
        try self.write(if (t.mutable) "var " else "const ");
        try self.write(struct_name);
        try self.write(".");
        try self.write(t.name);
        if (t.annotation) |a| {
            try self.write(": ");
            try self.printType(a);
        }
        try self.write(" = ");
        try self.printExpr(t.initializer);
    }

    // Types as written (§4, §7.1, §8.2).

    fn printType(self: *Printer, t: Ast.TypeExpression) PrintError!void {
        if (t.signature) |signature| {
            try self.write("func(");
            for (signature.parameters, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                try self.printType(p);
            }
            try self.write(")");
            if (signature.result) |result| {
                try self.write(": ");
                try self.printType(result.*);
            }
        } else if (t.positions) |positions| {
            try self.write("(");
            for (positions, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                try self.printType(p);
            }
            try self.write(")");
        } else if (t.element) |element| {
            if (t.key) |key| {
                try self.write("Dict[");
                try self.printType(key.*);
                try self.write(", ");
                try self.printType(element.*);
                try self.write("]");
            } else if (t.set) {
                try self.write("Set[");
                try self.printType(element.*);
                try self.write("]");
            } else {
                try self.write("List[");
                try self.printType(element.*);
                try self.write("]");
            }
        } else {
            try self.write(t.name);
        }
        if (t.question_span != null) try self.write("?");
    }

    // Expressions.

    /// Section 5.3's precedence, loosest first, as the exact chain of
    /// `Parser` functions builds it (`parseDisjunction` through
    /// `parsePostfix`): `or`, `and`, `not`, comparison chains and `is`,
    /// range, `+`/`-`, `*`/`/`/`//`/`%`, unary `-`, `**`, then calls, member
    /// access, and indexing, which bind tightest of all. Grouping
    /// parentheses leave no trace once parsed — `(a + b) * c` and a
    /// differently-grouped equivalent can produce the same tree only when
    /// they mean the same thing — so the printer must always re-derive
    /// which parentheses are load-bearing from precedence and associativity
    /// alone, never from whether the source happened to write any.
    const Level = enum(u8) { or_, and_, not_, comparison, range, additive, multiplicative, unary, power, postfix };

    fn levelOf(self: *Printer, expr: *const Ast.Expression) Level {
        return switch (expr.data) {
            // The one Int literal whose own span carries a sign: `parseUnary`
            // reads the minimum Int's magnitude as a single token so its
            // positive numeral is never a legal Int on its own (5.3), which
            // means it can only be written as `-9223372036854775808` and
            // never reaches `parsePostfix` the way an ordinary literal does.
            // `(-9223372036854775808).digits()` therefore needs its parens
            // kept, unlike every other literal, which is always safe to chain
            // `.member`/`(...)`/`[...]` off of directly.
            .int_literal => if (self.source.text[expr.span.start] == '-') .unary else .postfix,
            .logical => |l| if (l.operator == .disjunction) .or_ else .and_,
            .unary => |u| if (u.operator == .not) .not_ else .unary,
            .comparison, .type_test => .comparison,
            .range => .range,
            .binary => |b| switch (b.operator) {
                .add, .subtract => .additive,
                .multiply, .divide, .floor_divide, .remainder => .multiplicative,
                .power => .power,
            },
            else => .postfix,
        };
    }

    /// Prints `expr` as an operand that needs to bind at least as tightly as
    /// `min_level`, wrapping it in parentheses when it does not — or, when
    /// `strict`, when it binds exactly that tightly too, which is what a
    /// same-level operand needs on the side where reparsing it plain would
    /// re-associate it differently (the right side of a left-associative
    /// operator, the left side of a right-associative one).
    fn printOperand(self: *Printer, expr: *const Ast.Expression, min_level: Level, strict: bool) PrintError!void {
        const level = self.levelOf(expr);
        const needs_parens = @intFromEnum(level) < @intFromEnum(min_level) or (strict and level == min_level);
        if (needs_parens) {
            try self.write("(");
            try self.printExpr(expr);
            try self.write(")");
        } else {
            try self.printExpr(expr);
        }
    }

    fn printExpr(self: *Printer, expr: *const Ast.Expression) PrintError!void {
        switch (expr.data) {
            // Every leaf whose text is exactly what a reader wrote: the
            // cooked `Ast` value is never used here, since it would lose a
            // number's original digits, a string's original escapes, and a
            // triple-quoted string's original indentation.
            .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .string_literal, .interpolation => try self.writeSpan(expr.span),

            // Built only once an enum's type-level fields are set up (§12),
            // never by the parser: `Direction.north` in source reads the
            // field that holds one instead.
            .enum_value => unreachable,

            .case_expression => |c| try self.printCase(c, expr.span.end),
            .unary => |u| try self.printUnary(u),
            .binary => |b| try self.printBinary(b),
            .logical => |l| try self.printLogical(l),
            .comparison => |c| try self.printComparison(c),
            .call => |c| try self.printCall(c),
            .range => |r| try self.printRange(r),
            .list_literal => |items| try self.printDelimitedExprs(items, "[", "]"),
            .dictionary_literal => |entries| try self.printDictionary(entries),
            .index => |index| {
                try self.printOperand(index.base, .postfix, false);
                try self.write("[");
                try self.printExpr(index.index);
                try self.write("]");
            },
            .member => |m| try self.printMemberAccess(m),
            .lambda => |l| try self.printLambda(l, expr.span),
            .tuple_literal => |items| try self.printDelimitedExprs(items, "(", ")"),
            .type_test => |t| {
                try self.printOperand(t.value, .range, false);
                try self.write(" is ");
                try self.printType(t.target);
            },
        }
    }

    fn printUnary(self: *Printer, u: Ast.Expression.Unary) PrintError!void {
        const level: Level, const text = switch (u.operator) {
            .negate => .{ .unary, "-" },
            .not => .{ .not_, "not " },
        };
        try self.write(text);
        try self.printOperand(u.operand, level, false);
    }

    fn printBinary(self: *Printer, b: Ast.Expression.Binary) PrintError!void {
        const level: Level = switch (b.operator) {
            .add, .subtract => .additive,
            .multiply, .divide, .floor_divide, .remainder => .multiplicative,
            .power => .power,
        };
        // `**` is section 5.3's one right-associative operator: its left
        // operand needs parens at its own level, and its right operand does
        // not, exactly reversed from every left-associative operator here.
        const right_associative = b.operator == .power;
        try self.printOperand(b.left, level, right_associative);
        try self.write(" ");
        try self.write(b.operator.lexeme());
        try self.write(" ");
        try self.printOperand(b.right, level, !right_associative);
    }

    fn printLogical(self: *Printer, l: Ast.Expression.Logical) PrintError!void {
        const level: Level = if (l.operator == .disjunction) .or_ else .and_;
        try self.printOperand(l.left, level, false);
        try self.write(" ");
        try self.write(l.operator.lexeme());
        try self.write(" ");
        try self.printOperand(l.right, level, true);
    }

    fn printComparison(self: *Printer, c: Ast.Expression.Comparison) PrintError!void {
        try self.printOperand(c.operands[0], .range, false);
        for (c.operators, 1..) |operator, i| {
            try self.write(" ");
            try self.write(operator.lexeme());
            try self.write(" ");
            try self.printOperand(c.operands[i], .range, false);
        }
    }

    fn printRange(self: *Printer, r: Ast.Expression.Range) PrintError!void {
        try self.printOperand(r.start, .additive, false);
        try self.write(if (r.inclusive) ".." else "..<");
        try self.printOperand(r.end, .additive, false);
    }

    fn printMemberAccess(self: *Printer, m: Ast.Expression.Member) PrintError!void {
        try self.printOperand(m.base, .postfix, false);
        try self.write(".");
        if (m.position) |position| try self.writeInt(position) else try self.write(m.name);
    }

    fn printCall(self: *Printer, call: Ast.Expression.Call) PrintError!void {
        try self.printOperand(call.callee, .postfix, false);

        const total = call.arguments.len;
        const paren_count = if (call.trailing) total - 1 else total;
        if (!(call.trailing and paren_count == 0)) {
            try self.write("(");
            const multiline = self.exprsSpanMultipleLines(call.arguments[0..paren_count]);
            if (multiline) {
                // Unlike a list, dictionary, or tuple literal, a call's
                // argument list has no trailing comma in its grammar
                // (`Parser.finishCall`): one after the last argument is a
                // parse error, not a style choice.
                try self.write("\n");
                self.indent += 1;
                for (call.arguments[0..paren_count], 0..) |argument, i| {
                    try self.writeIndent();
                    try self.printArgumentName(call, i);
                    try self.printExpr(argument);
                    try self.write(if (i + 1 < paren_count) ",\n" else "\n");
                }
                self.indent -= 1;
                try self.writeIndent();
            } else {
                for (call.arguments[0..paren_count], 0..) |argument, i| {
                    if (i > 0) try self.write(", ");
                    try self.printArgumentName(call, i);
                    try self.printExpr(argument);
                }
            }
            try self.write(")");
        }

        if (call.trailing) {
            try self.write(" ");
            try self.printExpr(call.arguments[total - 1]);
        }
    }

    fn printArgumentName(self: *Printer, call: Ast.Expression.Call, index: usize) PrintError!void {
        if (index >= call.names.len) return;
        const name = call.names[index] orelse return;
        try self.write(name.text);
        try self.write(": ");
    }

    /// Shared by list and tuple literals, whose elements are both a plain
    /// `[]const *const Expression`. Dictionary entries need their own
    /// walk, for the `key: value` pairs.
    fn printDelimitedExprs(self: *Printer, items: []const *const Ast.Expression, open: []const u8, close: []const u8) PrintError!void {
        try self.write(open);
        if (items.len == 0) {
            try self.write(close);
            return;
        }
        const multiline = self.exprsSpanMultipleLines(items);
        if (multiline) {
            try self.write("\n");
            self.indent += 1;
            for (items) |item| {
                try self.writeIndent();
                try self.printExpr(item);
                try self.write(",\n");
            }
            self.indent -= 1;
            try self.writeIndent();
        } else {
            for (items, 0..) |item, i| {
                if (i > 0) try self.write(", ");
                try self.printExpr(item);
            }
        }
        try self.write(close);
    }

    /// A dictionary literal's `entries` is never empty: `[]` parses as an
    /// empty list, and only later, from the type expected where it is
    /// written, does the checker decide it is really an empty dictionary.
    fn printDictionary(self: *Printer, entries: []const Ast.Expression.Entry) PrintError!void {
        try self.write("[");
        var multiline = false;
        var gap: usize = 1;
        while (gap < entries.len) : (gap += 1) {
            if (self.spansMultipleLines(entries[gap - 1].value.span.end, entries[gap].key.span.start)) {
                multiline = true;
                break;
            }
        }
        if (multiline) {
            try self.write("\n");
            self.indent += 1;
            for (entries) |entry| {
                try self.writeIndent();
                try self.printExpr(entry.key);
                try self.write(": ");
                try self.printExpr(entry.value);
                try self.write(",\n");
            }
            self.indent -= 1;
            try self.writeIndent();
        } else {
            for (entries, 0..) |entry, i| {
                if (i > 0) try self.write(", ");
                try self.printExpr(entry.key);
                try self.write(": ");
                try self.printExpr(entry.value);
            }
        }
        try self.write("]");
    }

    fn printLambda(self: *Printer, lambda: Ast.Expression.Lambda, span: Source.Span) PrintError!void {
        try self.write("{ ");
        for (lambda.parameters, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            if (p.pattern) |pattern| {
                try self.printPattern(pattern);
            } else {
                try self.write(p.name);
                if (p.annotation) |a| {
                    try self.write(": ");
                    try self.printType(a);
                }
            }
        }
        if (lambda.parameters.len > 0) try self.write(" ");
        try self.write("=>");

        switch (lambda.body) {
            .expression => |e| {
                try self.write(" ");
                try self.printExpr(e);
                try self.write(" }");
            },
            .block => |block| {
                // A block body is only an expression's worth away from a
                // single-expression one when its statement is not itself an
                // expression — `{ price => total += price }`, an assignment,
                // reads no differently one line at a time — so it stays on
                // one line exactly when the source had nothing after `=>`
                // to force it onto more than one.
                if (block.statements.len == 1 and !self.spansMultipleLines(span.start, span.end)) {
                    try self.write(" ");
                    try self.printStatement(block.statements[0]);
                    try self.write(" }");
                    return;
                }
                try self.write("\n");
                try self.printStatementsIndented(block.statements, block.span.end);
                try self.writeIndent();
                try self.write("}");
            },
        }
    }
};

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const testing = std.testing;

/// Lexes, parses, and formats `text`, asserting both stages succeed. Callers
/// own the result.
fn formatText(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var source = try Source.init(gpa, "test.em", text);
    defer source.deinit(gpa);

    var tokenized = try Lexer.tokenize(gpa, &source);
    defer tokenized.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), tokenized.diagnostics.len);

    var parsed = try Parser.parse(gpa, &source, tokenized.tokens);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const formatted = try print(gpa, &source, tokenized.tokens, parsed.program);
    defer gpa.free(formatted);
    return try gpa.dupe(u8, formatted);
}

fn expectFormats(text: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const formatted = try formatText(gpa, text);
    defer gpa.free(formatted);
    try testing.expectEqualStrings(expected, formatted);
}

test "blank-line runs collapse to exactly one, and a block never starts or ends with one" {
    try expectFormats(
        "var a = 1\n\n\n\nvar b = 2\nif a == 1 {\n\n    print(a)\n\n}\n",
        "var a = 1\n\nvar b = 2\nif a == 1 {\n    print(a)\n}\n",
    );
}

test "a comment on the same line as a statement stays there" {
    try expectFormats(
        "print(1) # explains itself\nprint(2)\n",
        "print(1) # explains itself\nprint(2)\n",
    );
}

test "a block comment's interior survives untouched, unlike a line comment" {
    try expectFormats(
        "   # reindented\nfunc f() {\n    #[\n      kept\n    as written\n    ]#\n}\n",
        "# reindented\nfunc f() {\n    #[\n      kept\n    as written\n    ]#\n}\n",
    );
}

test "redundant grouping parentheses are dropped, load-bearing ones are kept" {
    try expectFormats(
        "const a = (1 + 2) * 3\nconst b = ((1 + 2))\n",
        "const a = (1 + 2) * 3\nconst b = 1 + 2\n",
    );
}

test "power's right associativity needs no parens on the right, but does on the left" {
    try expectFormats(
        "const a = 2 ** (3 ** 4)\nconst b = (2 ** 3) ** 4\n",
        "const a = 2 ** 3 ** 4\nconst b = (2 ** 3) ** 4\n",
    );
}

test "the minimum Int keeps its parentheses before a member access" {
    try expectFormats(
        "const a = (-9223372036854775808).digits()\n",
        "const a = (-9223372036854775808).digits()\n",
    );
}

test "a call's multi-line arguments never gain a trailing comma, unlike a list literal" {
    try expectFormats(
        "print(\n    1,\n    2\n)\nconst xs = [\n    1,\n    2\n]\n",
        "print(\n    1,\n    2\n)\nconst xs = [\n    1,\n    2,\n]\n",
    );
}

test "formatting already-canonical output is a no-op" {
    const gpa = testing.allocator;
    const once = try formatText(gpa, "struct Point {\n    var x: Float\n    var y: Float\n}\n\nprint(Point(1, 2))\n");
    defer gpa.free(once);
    const twice = try formatText(gpa, once);
    defer gpa.free(twice);
    try testing.expectEqualStrings(once, twice);
}
