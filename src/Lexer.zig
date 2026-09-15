//! Turns source text into tokens.
//!
//! Two rules here are less obvious than the rest and are worth stating up front.
//!
//! Newlines terminate statements, but only sometimes. Section 3.1 suppresses a
//! newline while a parenthesis or bracket is open, and after any token that
//! cannot end an expression. `Token.Kind.canEndExpression` owns that list.
//! Because `.newline` itself cannot end an expression, runs of blank lines
//! collapse into a single terminator without any special handling. The one
//! rule that looks forward instead is the leading dot: a line that begins with
//! `.` or `?.` continues the one before it, so a method chain can wrap.
//!
//! Section 3.3 lets a name end in `?` or `!`, which collides with the `?.`
//! operator and the `!=` operator. Maximal munch would turn `user?.name` into
//! the name `user?` and turn `a!=b` into the name `a!`. A trailing marker
//! therefore joins the name unless the character after it makes an operator:
//! `?` does not join when `.` follows, and `!` does not join when `=` follows.

const std = @import("std");
const Source = @import("Source.zig");
const Diagnostic = @import("Diagnostic.zig");
const Token = @import("Token.zig");
const unicode = @import("unicode.zig");

const Lexer = @This();

gpa: std.mem.Allocator,
source: *const Source,
index: u32 = 0,
/// Open `(` and `[`. Section 3.1 suppresses newlines inside them. Braces are
/// deliberately excluded: statement blocks keep normal newline termination, and
/// telling an expression-position brace from a block is the parser's job.
group_depth: u32 = 0,
/// `group_depth` as it was outside each open `{`. A brace starts afresh, so a
/// block or a `case` inside parentheses still ends its lines with newlines
/// (6.3, 7.4), and its `}` puts the outer suppression back.
brace_depths: std.ArrayList(u32) = .empty,
/// The last token emitted, for the continuation rule. Starting at `.newline`
/// makes leading blank lines disappear the same way interior ones do.
previous: Token.Kind = .newline,
diagnostics: std.ArrayList(Diagnostic) = .empty,
/// Strings whose `#{` has been read but not yet their closing `}`,
/// innermost last. A `}` that closes one resumes scanning that string.
interpolations: std.ArrayList(Interpolation) = .empty,

const Interpolation = struct {
    /// Where the string began, for reporting it unclosed.
    start: u32,
    /// Where its `#{` is, for reporting that unclosed instead.
    opening: u32,
    multiline: bool,
    /// Braces opened inside the interpolation and not yet closed, so that
    /// only the `}` matching `#{` resumes the string.
    braces: u32 = 0,
};

pub fn init(gpa: std.mem.Allocator, source: *const Source) Lexer {
    return .{ .gpa = gpa, .source = source };
}

pub fn deinit(self: *Lexer) void {
    self.diagnostics.deinit(self.gpa);
    self.interpolations.deinit(self.gpa);
    self.brace_depths.deinit(self.gpa);
    self.* = undefined;
}

/// All tokens in a source, ending with exactly one `.eof`, plus everything the
/// lexer had to report. The caller owns both slices.
pub const Tokenized = struct {
    tokens: []const Token,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Tokenized, gpa: std.mem.Allocator) void {
        gpa.free(self.tokens);
        gpa.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn tokenize(gpa: std.mem.Allocator, source: *const Source) !Tokenized {
    var lexer: Lexer = .init(gpa, source);
    defer lexer.deinit();

    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);

    while (true) {
        const token = try lexer.next();
        try tokens.append(gpa, token);
        if (token.kind == .eof) break;
    }

    return .{
        .tokens = try tokens.toOwnedSlice(gpa),
        .diagnostics = try lexer.diagnostics.toOwnedSlice(gpa),
    };
}

pub fn next(self: *Lexer) std.mem.Allocator.Error!Token {
    while (true) {
        self.skipSpacing();

        if (self.atEnd()) return self.emit(.eof, self.index, self.index);

        const start = self.index;
        switch (self.peek()) {
            '\n' => {
                self.index += 1;
                if (self.group_depth == 0 and self.previous.canEndExpression() and
                    !self.nextLineLeadsWithDot())
                {
                    return self.emit(.newline, start, self.index);
                }
                continue;
            },
            '#' => {
                if (try self.lexComment()) |token| return token;
                continue;
            },
            else => return self.lexToken(),
        }
    }
}

/// Section 3.1: a line whose first token is a member dot continues the line
/// before it, so a chain can put each step on its own line:
///
///     var count = numbers
///         .filter { number => number > 0 }
///         .count
///
/// Blank lines and line comments between the two are skipped. `..` is a range,
/// not a member dot, so a line beginning with it does not continue anything.
fn nextLineLeadsWithDot(self: Lexer) bool {
    var at = self.index;
    const text = self.source.text;
    while (at < text.len) {
        switch (text[at]) {
            ' ', '\t', '\r', '\n' => at += 1,
            '#' => {
                // Documentation and block comments end the search; only an
                // ordinary line comment is skipped.
                if (at + 1 < text.len and (text[at + 1] == '#' or text[at + 1] == '[')) return false;
                while (at < text.len and text[at] != '\n') at += 1;
            },
            '.' => return at + 1 >= text.len or text[at + 1] != '.',
            '?' => return at + 1 < text.len and text[at + 1] == '.',
            else => return false,
        }
    }
    return false;
}

// Scanning primitives.

fn atEnd(self: Lexer) bool {
    return self.index >= self.source.text.len;
}

fn peek(self: Lexer) u8 {
    return self.peekAt(0);
}

fn peekAt(self: Lexer, offset: u32) u8 {
    const at = self.index + offset;
    return if (at < self.source.text.len) self.source.text[at] else 0;
}

/// Horizontal whitespace only. Newlines are significant and handled by `next`.
/// A carriage return is spacing so that CRLF behaves exactly like LF.
fn skipSpacing(self: *Lexer) void {
    while (!self.atEnd()) : (self.index += 1) {
        switch (self.peek()) {
            ' ', '\t', '\r' => {},
            else => break,
        }
    }
}

fn emit(self: *Lexer, kind: Token.Kind, start: u32, end: u32) Token {
    self.previous = kind;
    return .{ .kind = kind, .span = .{ .start = start, .end = end } };
}

fn report(
    self: *Lexer,
    span: Source.Span,
    message: []const u8,
    help: []const u8,
) std.mem.Allocator.Error!void {
    try self.diagnostics.append(self.gpa, .{
        .message = message,
        .span = span,
        .help = help,
    });
}

// Comments.

/// Returns a token for a documentation comment, which the parser needs, and null
/// for an ordinary comment, which is skipped.
fn lexComment(self: *Lexer) std.mem.Allocator.Error!?Token {
    const start = self.index;

    // Section 3.2: the next character alone decides the form. A run of three or
    // more hashes is a documentation comment whose text happens to begin with a
    // hash, not some further variety of comment.
    switch (self.peekAt(1)) {
        '[' => {
            try self.skipBlockComment();
            return null;
        },
        '#' => {
            self.skipToLineEnd();
            return self.emit(.doc_comment, start, self.index);
        },
        else => {
            self.skipToLineEnd();
            return null;
        },
    }
}

fn skipToLineEnd(self: *Lexer) void {
    while (!self.atEnd() and self.peek() != '\n') self.index += 1;
}

/// Block comments nest. An unclosed one is reported at its opening `#[` rather
/// than at the end of the file, because the opening is what the reader must fix.
fn skipBlockComment(self: *Lexer) std.mem.Allocator.Error!void {
    const opening: Source.Span = .{ .start = self.index, .end = self.index + 2 };
    self.index += 2;

    var depth: u32 = 1;
    while (!self.atEnd()) {
        if (self.peek() == '#' and self.peekAt(1) == '[') {
            depth += 1;
            self.index += 2;
        } else if (self.peek() == ']' and self.peekAt(1) == '#') {
            depth -= 1;
            self.index += 2;
            if (depth == 0) return;
        } else {
            self.index += 1;
        }
    }

    try self.report(
        opening,
        "this block comment is never closed",
        "Close it with `]#`.",
    );
}

// Tokens.

fn lexToken(self: *Lexer) std.mem.Allocator.Error!Token {
    const start = self.index;
    const c = self.peek();

    if (isDigit(c)) return self.lexNumber();
    if (self.startsIdentifier()) return self.lexIdentifier();

    switch (c) {
        '"' => return self.lexDoubleQuoted(),
        '\'' => return self.lexRawString(),
        else => {},
    }

    self.index += 1;
    const kind: Token.Kind = switch (c) {
        '+' => if (self.take('=')) .plus_equal else .plus,
        '-' => if (self.take('=')) .minus_equal else .minus,
        '%' => .percent,
        '(' => blk: {
            self.group_depth += 1;
            break :blk .left_paren;
        },
        ')' => blk: {
            if (self.group_depth > 0) self.group_depth -= 1;
            break :blk .right_paren;
        },
        '[' => blk: {
            self.group_depth += 1;
            break :blk .left_bracket;
        },
        ']' => blk: {
            if (self.group_depth > 0) self.group_depth -= 1;
            break :blk .right_bracket;
        },
        '{' => blk: {
            if (self.interpolations.items.len > 0) self.interpolations.items[self.interpolations.items.len - 1].braces += 1;
            try self.brace_depths.append(self.gpa, self.group_depth);
            self.group_depth = 0;
            break :blk .left_brace;
        },
        '}' => blk: {
            if (self.interpolations.items.len > 0) {
                const open = &self.interpolations.items[self.interpolations.items.len - 1];
                if (open.braces == 0) return self.scanString(start, open.multiline, true);
                open.braces -= 1;
            }
            if (self.brace_depths.pop()) |outer| self.group_depth = outer;
            break :blk .right_brace;
        },
        ',' => .comma,
        ':' => .colon,
        '@' => .at,
        '?' => if (self.take('.')) .question_dot else .question,
        '*' => if (self.take('*')) .star_star else if (self.take('=')) .star_equal else .star,
        '=' => if (self.take('=')) .equal_equal else if (self.take('>')) .fat_arrow else .equal,
        '<' => if (self.take('=')) .less_equal else .less,
        '>' => if (self.take('=')) .greater_equal else .greater,
        '/' => if (self.take('/'))
            (if (self.take('=')) .slash_slash_equal else .slash_slash)
        else if (self.take('='))
            .slash_equal
        else
            .slash,
        '.' => if (self.take('.'))
            (if (self.take('<')) .dot_dot_less else .dot_dot)
        else
            .dot,
        '!' => blk: {
            if (self.take('=')) break :blk .bang_equal;
            try self.report(
                .{ .start = start, .end = self.index },
                "`!` is not an operator in Emerald",
                "Write `not` for negation, or `!=` to compare for inequality.",
            );
            break :blk .invalid;
        },
        // Section 3.1 keeps semicolons out of the language entirely, so saying so
        // is more useful than calling this an unrecognized character.
        ';' => blk: {
            try self.report(
                .{ .start = start, .end = self.index },
                "Emerald does not use semicolons",
                "Remove it. A new line ends a statement.",
            );
            break :blk .invalid;
        },
        else => blk: {
            // Consume the whole UTF-8 sequence so one stray character produces
            // one diagnostic rather than one per byte.
            const width = std.unicode.utf8ByteSequenceLength(c) catch 1;
            self.index = @min(start + width, @as(u32, @intCast(self.source.text.len)));
            if (c >= 0x80) {
                // Section 3.3: names use Unicode's identifier characters, which
                // leave out emoji and symbols.
                try self.report(
                    .{ .start = start, .end = self.index },
                    "this character cannot be used in a name",
                    "Names are made of letters, digits, and underscores. Emoji and symbols belong inside strings.",
                );
            } else {
                try self.report(
                    .{ .start = start, .end = self.index },
                    "this character does not belong here",
                    "Remove it, or check for a typo nearby.",
                );
            }
            break :blk .invalid;
        },
    };

    return self.emit(kind, start, self.index);
}

fn take(self: *Lexer, expected: u8) bool {
    if (self.peek() != expected) return false;
    self.index += 1;
    return true;
}

// Identifiers.

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Section 3.3: names follow Unicode's identifier rules (UAX #31's XID
/// classes, which leave out emoji), with ASCII taken on a fast path.
fn startsIdentifier(self: Lexer) bool {
    const c = self.peek();
    if (c < 0x80) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    const code_point, _ = unicode.decode(self.source.text, self.index);
    return unicode.isIdentifierStart(code_point);
}

/// The length of the identifier character at the current position, or 0.
fn identifierContinues(self: Lexer) u32 {
    const c = self.peek();
    if (c < 0x80) {
        const part = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or isDigit(c);
        return if (part) 1 else 0;
    }
    const code_point, const length = unicode.decode(self.source.text, self.index);
    return if (unicode.isIdentifierContinue(code_point)) length else 0;
}

fn skipIdentifierCharacters(self: *Lexer) void {
    while (!self.atEnd()) {
        const length = self.identifierContinues();
        if (length == 0) return;
        self.index += length;
    }
}

fn lexIdentifier(self: *Lexer) Token {
    const start = self.index;
    self.skipIdentifierCharacters();

    // A single trailing `?` or `!` belongs to the name, unless the character
    // after it would form `?.` or `!=`.
    switch (self.peek()) {
        '?' => if (self.peekAt(1) != '.') {
            self.index += 1;
        },
        '!' => if (self.peekAt(1) != '=') {
            self.index += 1;
        },
        else => {},
    }

    const text = self.source.text[start..self.index];
    if (std.mem.eql(u8, text, "_")) return self.emit(.underscore, start, self.index);
    const kind = Token.keywords.get(text) orelse .identifier;
    return self.emit(kind, start, self.index);
}

// Numbers.

fn lexNumber(self: *Lexer) std.mem.Allocator.Error!Token {
    const start = self.index;

    if (self.peek() == '0') {
        switch (self.peekAt(1)) {
            'x', 'X', 'o', 'O', 'b', 'B' => return self.rejectNonDecimal(start),
            else => {},
        }
    }

    var malformed = !self.consumeDigits();
    var kind: Token.Kind = .int_literal;

    // A decimal point makes a float only when a digit follows it. Otherwise the
    // dot belongs to the next token, which is what makes `5.times` a method call
    // and `1..5` a range rather than malformed numbers.
    if (self.peek() == '.' and isDigit(self.peekAt(1))) {
        kind = .float_literal;
        self.index += 1;
        if (!self.consumeDigits()) malformed = true;
    }

    if (self.peek() == 'e' or self.peek() == 'E') {
        const after_sign: u32 = if (self.peekAt(1) == '+' or self.peekAt(1) == '-') 2 else 1;
        if (isDigit(self.peekAt(after_sign))) {
            kind = .float_literal;
            self.index += after_sign;
            if (!self.consumeDigits()) malformed = true;
        } else {
            // `1e` and `1e+` are attempted exponents, not a number beside a name.
            kind = .float_literal;
            self.index += after_sign;
            malformed = true;
        }
    }

    // Anything immediately adjacent means the whole run was one attempted
    // literal; section 5.1 wants one error spanning it rather than a number
    // followed by a puzzling name.
    if (!self.atEnd() and self.identifierContinues() > 0) {
        self.skipIdentifierCharacters();
        malformed = true;
    }

    if (malformed) {
        try self.report(
            .{ .start = start, .end = self.index },
            "this is not a valid number",
            "Write a decimal number such as `42` or `3.5`. `_` may separate digits, as in `1_000`.",
        );
        return self.emit(.invalid, start, self.index);
    }

    return self.emit(kind, start, self.index);
}

fn rejectNonDecimal(self: *Lexer, start: u32) std.mem.Allocator.Error!Token {
    self.index += 2;
    self.skipIdentifierCharacters();
    try self.report(
        .{ .start = start, .end = self.index },
        "Emerald writes numbers in decimal only",
        "Write the value as a decimal number. Hexadecimal, octal, and binary literals are not available.",
    );
    return self.emit(.invalid, start, self.index);
}

/// Consumes a digit run that may contain separating underscores. Returns false
/// when an underscore leads, trails, or repeats.
fn consumeDigits(self: *Lexer) bool {
    var well_formed = self.peek() != '_';
    var previous_underscore = false;
    var digits: u32 = 0;

    while (!self.atEnd()) {
        const c = self.peek();
        if (isDigit(c)) {
            digits += 1;
            previous_underscore = false;
        } else if (c == '_') {
            if (previous_underscore) well_formed = false;
            previous_underscore = true;
        } else break;
        self.index += 1;
    }

    if (previous_underscore) well_formed = false; // trailing
    return well_formed and digits > 0;
}

// Strings.
//
// Only the boundaries are found here; the parser cooks escapes, indentation,
// and interpolation into values. A string with interpolation is emitted in
// parts, with the tokens of each interpolated expression between them, so a
// quote inside `#{...}` belongs to the expression rather than ending the
// string.

fn lexDoubleQuoted(self: *Lexer) std.mem.Allocator.Error!Token {
    const start = self.index;
    const multiline = self.peekAt(1) == '"' and self.peekAt(2) == '"';
    self.index += if (multiline) 3 else 1;
    return self.scanString(start, multiline, false);
}

/// Scans string text from the current position up to its end, or up to the
/// next `#{`. `resuming` means `start` is the `}` that closed an
/// interpolation rather than the opening quote.
fn scanString(self: *Lexer, start: u32, multiline: bool, resuming: bool) std.mem.Allocator.Error!Token {
    // When resuming, `lexToken` has already stepped past the `}`.
    while (!self.atEnd()) {
        const c = self.peek();
        if (c == '"' and (!multiline or (self.peekAt(1) == '"' and self.peekAt(2) == '"'))) {
            self.index += if (multiline) 3 else 1;
            if (!resuming) {
                return self.emit(if (multiline) .multiline_string_literal else .string_literal, start, self.index);
            }
            _ = self.interpolations.pop();
            self.group_depth -|= 1;
            return self.emit(.string_end, start, self.index);
        }
        if (c == '#' and self.peekAt(1) == '{') {
            self.index += 2;
            if (resuming) return self.emit(.string_middle, start, self.index);
            try self.interpolations.append(self.gpa, .{
                .start = start,
                .opening = self.index - 2,
                .multiline = multiline,
            });
            // Newlines inside an interpolation continue it, as inside `(`.
            self.group_depth += 1;
            return self.emit(.string_start, start, self.index);
        }
        switch (c) {
            '\\' => try self.consumeEscape(),
            '\n' => if (multiline) {
                self.index += 1;
            } else break,
            else => self.index += 1,
        }
    }

    if (!resuming and self.interpolations.items.len > 0) {
        // A string that began inside `#{...}` and ran off the line: far more
        // often the `}` was forgotten and this quote was meant to close the
        // outer string. Say that, and stop tracking the interpolations.
        const open = self.interpolations.items[self.interpolations.items.len - 1];
        self.group_depth -|= @intCast(self.interpolations.items.len);
        self.interpolations.clearRetainingCapacity();
        try self.report(
            .{ .start = open.opening, .end = open.opening + 2 },
            "this `#{` is never closed",
            "End the interpolation with `}` before the string's closing quote, as in `\"#{count}\"`.",
        );
        return self.emit(.invalid, start, self.index);
    }

    const opening = if (resuming) blk: {
        const open = self.interpolations.pop().?;
        self.group_depth -|= 1;
        break :blk open.start;
    } else start;
    return self.unterminated(opening, if (multiline) "\"\"\"" else "\"");
}

fn lexRawString(self: *Lexer) std.mem.Allocator.Error!Token {
    const start = self.index;
    self.index += 1;
    while (!self.atEnd()) {
        switch (self.peek()) {
            '\'' => {
                self.index += 1;
                return self.emit(.raw_string_literal, start, self.index);
            },
            // Raw strings process no escapes, so a backslash is ordinary text.
            '\n' => break,
            else => self.index += 1,
        }
    }

    return self.unterminated(start, "'");
}

fn consumeEscape(self: *Lexer) std.mem.Allocator.Error!void {
    const start = self.index;
    self.index += 1;
    if (self.atEnd()) return;

    switch (self.peek()) {
        // `\#` escapes an interpolation opener, per section 5.1.
        'n', 't', 'r', '0', '\\', '"', '\'', '#' => self.index += 1,
        'u' => try self.consumeUnicodeEscape(start),
        else => {
            const width = std.unicode.utf8ByteSequenceLength(self.peek()) catch 1;
            self.index = @min(self.index + width, @as(u32, @intCast(self.source.text.len)));
            try self.report(
                .{ .start = start, .end = self.index },
                "this escape is not recognized",
                "Emerald understands `\\n`, `\\t`, `\\r`, `\\0`, `\\\\`, `\\\"`, `\\'`, `\\#`, and `\\u{...}`.",
            );
        },
    }
}

/// `\u{1F600}`: a Unicode scalar value written as one to six hex digits,
/// for characters that are invisible or awkward to type, such as a combining
/// accent. Surrogates are not scalar values, so they are refused.
fn consumeUnicodeEscape(self: *Lexer, start: u32) std.mem.Allocator.Error!void {
    self.index += 1; // `u`
    if (self.peek() == '{') {
        self.index += 1;
        const digits_start = self.index;
        while (!self.atEnd() and std.ascii.isHex(self.peek())) self.index += 1;
        const digits = self.source.text[digits_start..self.index];
        if (self.peek() == '}' and digits.len > 0 and digits.len <= 6) {
            self.index += 1;
            const value = std.fmt.parseInt(u32, digits, 16) catch unreachable;
            if (value <= 0x10FFFF and (value < 0xD800 or value > 0xDFFF)) return;
            return self.report(
                .{ .start = start, .end = self.index },
                "this `\\u` escape is not a Unicode character",
                "Characters run from `\\u{0}` to `\\u{10FFFF}`, skipping `\\u{D800}` through `\\u{DFFF}`.",
            );
        }
        if (self.peek() == '}') self.index += 1;
    }
    try self.report(
        .{ .start = start, .end = self.index },
        "this `\\u` escape is incomplete",
        "Write the character's code point as one to six hex digits in braces, as in `\\u{E9}` for é.",
    );
}

fn unterminated(
    self: *Lexer,
    start: u32,
    delimiter: []const u8,
) std.mem.Allocator.Error!Token {
    try self.report(
        .{ .start = start, .end = start + @as(u32, @intCast(delimiter.len)) },
        "this string is never closed",
        if (delimiter.len == 3)
            "Close it with `\"\"\"` on a line of its own."
        else if (delimiter[0] == '\'')
            "Close it with `'` before the line ends."
        else
            "Close it with `\"` before the line ends.",
    );
    return self.emit(.invalid, start, self.index);
}

const testing = std.testing;

fn expectKinds(text: []const u8, expected: []const Token.Kind) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    var actual: std.ArrayList(Token.Kind) = .empty;
    defer actual.deinit(testing.allocator);
    for (result.tokens) |token| try actual.append(testing.allocator, token.kind);

    try testing.expectEqualSlices(Token.Kind, expected, actual.items);
}

/// Asserts the source text each token covers, which pins the span arithmetic as
/// well as the token kinds.
fn expectTexts(text: []const u8, expected: []const []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(expected.len, result.tokens.len - 1); // less `.eof`
    for (expected, result.tokens[0 .. result.tokens.len - 1]) |want, token| {
        try testing.expectEqualStrings(want, source.text[token.span.start..token.span.end]);
    }
}

fn expectDiagnostic(text: []const u8, expected_message: []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    try testing.expect(result.diagnostics.len >= 1);
    try testing.expectEqualStrings(expected_message, result.diagnostics[0].message);
}

fn expectNoDiagnostics(text: []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    if (result.diagnostics.len != 0) {
        std.debug.print("unexpected: {s}\n", .{result.diagnostics[0].message});
        return error.UnexpectedDiagnostic;
    }
}

test "the first milestone program" {
    try expectKinds("var score = 2 + 3 * 4\nprint(score) # 14\n", &.{
        .keyword_var, .identifier, .equal,       .int_literal, .plus,
        .int_literal, .star,       .int_literal, .newline,     .identifier,
        .left_paren,  .identifier, .right_paren, .newline,     .eof,
    });
}

test "keywords are recognized and other names are not" {
    try expectKinds("var const func score", &.{
        .keyword_var, .keyword_const, .keyword_func, .identifier, .eof,
    });
    // Contextual words stay ordinary names, per the table in Token.zig.
    try expectKinds("get set value", &.{ .identifier, .identifier, .identifier, .eof });
}

// Section 3.1: the continuation rule.

test "a newline after a token that can end an expression terminates the statement" {
    try expectKinds("1\n2\n", &.{ .int_literal, .newline, .int_literal, .newline, .eof });
}

test "a newline after a binary operator continues the statement" {
    try expectKinds("1 +\n2", &.{ .int_literal, .plus, .int_literal, .eof });
}

test "a newline after a comma or member dot continues the statement" {
    try expectKinds("f(1,\n2)", &.{
        .identifier,  .left_paren,  .int_literal, .comma,
        .int_literal, .right_paren, .eof,
    });
    try expectKinds("value.\nfield", &.{ .identifier, .dot, .identifier, .eof });
}

test "a line that begins with a member dot continues the line before it" {
    try expectKinds("numbers\n    .count\n", &.{ .identifier, .dot, .identifier, .newline, .eof });
    try expectKinds("user\n    ?.name\n", &.{ .identifier, .question_dot, .identifier, .newline, .eof });
    // Blank lines and ordinary comments between do not break the chain.
    try expectKinds("a\n\n    # why\n    .b\n", &.{ .identifier, .dot, .identifier, .newline, .eof });
    // A range and a documentation comment do not continue anything.
    try expectKinds("a\n..b", &.{ .identifier, .newline, .dot_dot, .identifier, .eof });
    try expectKinds("a\n## doc\n.b", &.{ .identifier, .newline, .doc_comment, .dot, .identifier, .eof });
}

test "newlines are suppressed while parentheses or brackets are open" {
    try expectKinds("print(\n  1,\n  2\n)\n", &.{
        .identifier,  .left_paren,  .int_literal, .comma,
        .int_literal, .right_paren, .newline,     .eof,
    });
    try expectKinds("[\n1,\n2\n]\n", &.{
        .left_bracket, .int_literal, .comma, .int_literal, .right_bracket, .newline, .eof,
    });
}

test "a brace inside parentheses ends its lines again until it closes" {
    try expectKinds("f({\n1\n2\n}\n)\n", &.{
        .identifier,  .left_paren,  .left_brace,  .int_literal, .newline, .int_literal,
        .newline,     .right_brace, .right_paren, .newline,     .eof,
    });
}

test "statement blocks keep normal newline termination" {
    // Braces do not open a group, so statements inside a block still end at a
    // newline. The newline directly after `{` is suppressed only because `{`
    // cannot end an expression, which is the same rule every other token follows.
    try expectKinds("if a {\nb\n}\n", &.{
        .keyword_if, .identifier,  .left_brace, .identifier,
        .newline,    .right_brace, .newline,    .eof,
    });
}

test "runs of blank lines collapse into one terminator" {
    try expectKinds("1\n\n\n\n2\n", &.{
        .int_literal, .newline, .int_literal, .newline, .eof,
    });
}

test "leading and trailing blank lines produce no stray terminators" {
    try expectKinds("\n\n1", &.{ .int_literal, .eof });
    try expectKinds("1\n\n\n", &.{ .int_literal, .newline, .eof });
}

test "a bare return may end a line" {
    try expectKinds("return\n", &.{ .keyword_return, .newline, .eof });
}

// Section 3.3 and 4.2: `?` and `!` as name suffixes.

test "a trailing question mark belongs to the name" {
    try expectTexts("list.empty?()", &.{ "list", ".", "empty?", "(", ")" });
}

test "a trailing bang belongs to the name" {
    try expectTexts("list.sort!()", &.{ "list", ".", "sort!", "(", ")" });
}

test "a question mark before a dot is optional chaining, not part of the name" {
    try expectKinds("user?.address", &.{ .identifier, .question_dot, .identifier, .eof });
    try expectTexts("user?.address", &.{ "user", "?.", "address" });
}

test "a bang before an equals is the inequality operator, not part of the name" {
    try expectKinds("a!=b", &.{ .identifier, .bang_equal, .identifier, .eof });
    try expectTexts("a != b", &.{ "a", "!=", "b" });
}

test "the optional type conformance case from section 4.2" {
    // `valid?` keeps its marker as part of the declared name, while the
    // parameter type `Int?` is lexed as one identifier for the parser to split.
    try expectTexts("func valid?(input: Int?): Bool {\n", &.{
        "func", "valid?", "(", "input", ":", "Int?", ")", ":", "Bool", "{",
    });
}

test "a string with interpolation arrives in parts around its expressions" {
    try expectKinds("\"a #{b} c\"", &.{ .string_start, .identifier, .string_end, .eof });
    try expectKinds("\"#{a} and #{b}\"", &.{ .string_start, .identifier, .string_middle, .identifier, .string_end, .eof });
    // A quote inside an interpolation belongs to a nested string.
    try expectKinds("\"x #{\"y\"} z\"", &.{ .string_start, .string_literal, .string_end, .eof });
    // A brace inside the interpolation does not end it.
    try expectKinds("\"#{f({})}\"", &.{
        .string_start, .identifier, .left_paren, .left_brace, .right_brace, .right_paren, .string_end, .eof,
    });
    // `\#{` is an escaped opener, so the string has no parts.
    try expectKinds("\"\\#{x}\"", &.{ .string_literal, .eof });
}

test "names use Unicode identifier characters" {
    try expectKinds("\u{FC}ber caf\u{E9} \u{5B57}", &.{ .identifier, .identifier, .identifier, .eof });
    try expectKinds("e\u{301}", &.{ .identifier, .eof });
}

test "an optional collection type puts the question mark on its own" {
    try expectKinds("var a: [String]?", &.{
        .keyword_var, .identifier,    .colon,    .left_bracket,
        .identifier,  .right_bracket, .question, .eof,
    });
}

test "a bare underscore is not an identifier but a leading underscore is" {
    try expectKinds("_ _total", &.{ .underscore, .identifier, .eof });
}

test "a lone bang is rejected with a pointer to `not`" {
    try expectDiagnostic("!a", "`!` is not an operator in Emerald");
}

// Section 5.1: numeric literals.

test "integers and floats" {
    try expectKinds("42", &.{ .int_literal, .eof });
    try expectKinds("3.5", &.{ .float_literal, .eof });
    try expectKinds("1e6", &.{ .float_literal, .eof });
    try expectKinds("1.5e-3", &.{ .float_literal, .eof });
    try expectKinds("2E+10", &.{ .float_literal, .eof });
    try expectNoDiagnostics("42 3.5 1e6 1.5e-3 2E+10");
}

test "underscores may separate digits" {
    try expectKinds("1_000_000", &.{ .int_literal, .eof });
    try expectNoDiagnostics("1_000_000");
}

test "underscores may not repeat or trail" {
    try expectDiagnostic("1__0", "this is not a valid number");
    try expectDiagnostic("1_", "this is not a valid number");
}

test "a method call on an integer is not a malformed float" {
    // The dot is only a decimal point when a digit follows it, which is what
    // keeps `5.times` and `1.up_to(5)` working.
    try expectTexts("5.times", &.{ "5", ".", "times" });
    try expectNoDiagnostics("5.times");
}

test "a range is not a malformed float" {
    try expectKinds("1..5", &.{ .int_literal, .dot_dot, .int_literal, .eof });
    try expectKinds("0..<10", &.{ .int_literal, .dot_dot_less, .int_literal, .eof });
    try expectNoDiagnostics("1..5 0..<10");
}

test "unsupported bases get one targeted diagnostic" {
    try expectDiagnostic("0xFF", "Emerald writes numbers in decimal only");
    try expectDiagnostic("0b1010", "Emerald writes numbers in decimal only");
    try expectDiagnostic("0o777", "Emerald writes numbers in decimal only");
    // One token, not a number beside a name.
    try expectKinds("0xFF", &.{ .invalid, .eof });
}

test "a malformed literal spans the whole attempted token" {
    try expectKinds("1abc", &.{ .invalid, .eof });
    try expectTexts("1abc", &.{"1abc"});
    try expectDiagnostic("1e", "this is not a valid number");
}

// Section 5.1: strings.

test "string forms" {
    try expectKinds("\"hello\"", &.{ .string_literal, .eof });
    try expectKinds("'raw\\d+'", &.{ .raw_string_literal, .eof });
    try expectKinds("\"\"\"\nmultiline\n\"\"\"", &.{ .multiline_string_literal, .eof });
    try expectNoDiagnostics("\"hello\" 'raw\\d+'");
}

test "a raw string processes no escapes" {
    try expectTexts("'C:\\Users\\student'", &.{"'C:\\Users\\student'"});
    try expectNoDiagnostics("'C:\\Users\\student'");
}

test "recognized escapes are accepted and others are reported" {
    try expectNoDiagnostics("\"a\\nb\\tc\\\\d\\\"e\\#{f\"");
    try expectDiagnostic("\"a\\qb\"", "this escape is not recognized");
}

test "an unterminated string is reported at its opening quote" {
    try expectDiagnostic("\"hello\n", "this string is never closed");
    try expectDiagnostic("'hello\n", "this string is never closed");
}

// Section 3.2: comments.

test "line comments are skipped and documentation comments are kept" {
    try expectKinds("1 # trailing\n", &.{ .int_literal, .newline, .eof });
    try expectKinds("## docs\nfunc f() {}", &.{
        .doc_comment, .keyword_func, .identifier,  .left_paren,
        .right_paren, .left_brace,   .right_brace, .eof,
    });
}

test "a third hash is documentation text, not a third comment form" {
    try expectKinds("### still docs\n", &.{ .doc_comment, .eof });
}

test "block comments nest" {
    try expectKinds("1 #[ outer #[ inner ]# outer ]# 2", &.{
        .int_literal, .int_literal, .eof,
    });
    try expectNoDiagnostics("#[ outer #[ inner ]# outer ]#");
}

test "an unclosed block comment is reported at its opening" {
    try expectDiagnostic("#[ never closed\n", "this block comment is never closed");

    var source = try Source.init(testing.allocator, "test.em", "var x = 1\n#[ oops\n");
    defer source.deinit(testing.allocator);
    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    // The span points at the `#[`, not at the end of the file.
    const span = result.diagnostics[0].span;
    try testing.expectEqualStrings("#[", source.text[span.start..span.end]);
    try testing.expectEqual(@as(u32, 2), source.location(span.start).line);
}

test "a semicolon is rejected with an explanation rather than accepted quietly" {
    try expectDiagnostic("var x = 1;", "Emerald does not use semicolons");
}

test "a stray character is reported once, not once per byte" {
    // A multi-byte character that is not a letter. Non-ASCII bytes are currently
    // accepted inside names, so this uses an ASCII character outside the
    // operator set to exercise the stray-character path.
    var source = try Source.init(testing.allocator, "test.em", "var x = $");
    defer source.deinit(testing.allocator);
    var result = try tokenize(testing.allocator, &source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqualStrings("this character does not belong here", result.diagnostics[0].message);
}

test "malformed inputs remain diagnosable without breaking the token stream" {
    const samples = [_][]const u8{
        "var name = \"Ava\n",
        "var age = 1 +\n",
        "if (\n",
        "func bad(1,\n",
        "a?.\n",
        "\"\\u{110000}\"\n",
        "\"\\u{1F600\n",
        "[\n",
        "{\n",
        "#[ nested\n",
        "1__0\n",
        "..\n",
        "user?.\n",
        "var x = $\n",
    };

    for (samples) |text| {
        var source = try Source.init(testing.allocator, "test.em", text);
        defer source.deinit(testing.allocator);

        var result = try tokenize(testing.allocator, &source);
        defer result.deinit(testing.allocator);

        try testing.expect(result.tokens.len > 0);
        try testing.expectEqual(@as(Token.Kind, .eof), result.tokens[result.tokens.len - 1].kind);
        if (result.diagnostics.len == 0) {
            for (result.tokens) |token| {
                try testing.expect(token.kind != .invalid);
            }
        }
    }
}

test "every operator and delimiter round-trips through its lexeme" {
    try expectTexts("+ - * ** / // % += -= *= /= //=", &.{
        "+", "-", "*", "**", "/", "//", "%", "+=", "-=", "*=", "/=", "//=",
    });
    try expectTexts("= == != < <= > >= => @ , : . .. ..< ?", &.{
        "=", "==", "!=", "<", "<=", ">", ">=", "=>", "@", ",", ":", ".", "..", "..<", "?",
    });
}

test "a windows line ending behaves exactly like a unix one" {
    try expectKinds("1\r\n2\r\n", &.{ .int_literal, .newline, .int_literal, .newline, .eof });
}
