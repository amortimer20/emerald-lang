//! One lexical token and its source span.

const std = @import("std");
const Source = @import("Source.zig");

const Token = @This();

kind: Kind,
span: Source.Span,

pub const Kind = enum {
    // Literals. Strings carry their delimiters in the span; their cooked value
    // is produced later, when a stage actually needs the text.
    int_literal,
    float_literal,
    /// A double-quoted string.
    string_literal,
    /// A single-quoted string. Raw: no escapes, no interpolation.
    raw_string_literal,
    /// A triple-double-quoted string.
    multiline_string_literal,
    /// A string with interpolation arrives in parts, with the tokens of each
    /// interpolated expression between them: `"Hi, #{name}!"` is the start
    /// `"Hi, #{`, the tokens of `name`, and the end `}!"`. A middle part,
    /// `} and #{`, sits between two interpolations.
    string_start,
    string_middle,
    string_end,

    identifier,
    /// A `##` documentation comment, which attaches to the declaration below it.
    doc_comment,

    keyword_and,
    keyword_assert,
    keyword_break,
    keyword_case,
    keyword_catch,
    keyword_class,
    keyword_const,
    keyword_constructor,
    keyword_continue,
    keyword_else,
    keyword_enum,
    keyword_extends,
    keyword_false,
    keyword_finally,
    keyword_for,
    keyword_func,
    keyword_if,
    keyword_in,
    keyword_is,
    keyword_not,
    keyword_nothing,
    keyword_or,
    keyword_raise,
    keyword_return,
    keyword_self,
    keyword_struct,
    keyword_super,
    keyword_then,
    keyword_trait,
    keyword_true,
    keyword_try,
    keyword_using,
    keyword_var,
    keyword_when,
    keyword_while,
    keyword_with,

    plus,
    minus,
    star,
    star_star,
    slash,
    slash_slash,
    percent,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    slash_slash_equal,

    equal,
    equal_equal,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,

    left_paren,
    right_paren,
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,

    comma,
    colon,
    dot,
    dot_dot,
    dot_dot_less,
    question,
    question_dot,
    fat_arrow,
    at,
    /// A bare `_`, which discards rather than binding. `_name` is an identifier.
    underscore,

    /// A statement terminator. Only emitted where a newline actually ends a
    /// statement; see `Lexer` for the continuation rule.
    newline,
    eof,
    /// A span the lexer could not make a token from. A diagnostic always
    /// accompanies it, so later stages may ignore it without reporting again.
    invalid,

    /// Whether a token may be the last token of an expression.
    ///
    /// This is the continuation-token list section 3.1 refers to: a newline
    /// following a token that cannot end an expression is a continuation rather
    /// than a statement terminator. Keeping the answer on `Kind` means the list
    /// is exhaustive by construction, because adding a kind without classifying
    /// it fails to compile.
    pub fn canEndExpression(kind: Kind) bool {
        return switch (kind) {
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .multiline_string_literal,
            .string_end,
            .identifier,
            .keyword_break,
            .keyword_continue,
            .keyword_false,
            .keyword_nothing,
            .keyword_return,
            .keyword_self,
            .keyword_super,
            .keyword_true,
            .right_paren,
            .right_bracket,
            .right_brace,
            .question,
            .underscore,
            .invalid,
            => true,

            .doc_comment,
            .string_start,
            .string_middle,
            .keyword_and,
            .keyword_assert,
            .keyword_case,
            .keyword_catch,
            .keyword_class,
            .keyword_const,
            .keyword_constructor,
            .keyword_else,
            .keyword_enum,
            .keyword_extends,
            .keyword_finally,
            .keyword_for,
            .keyword_func,
            .keyword_if,
            .keyword_in,
            .keyword_is,
            .keyword_not,
            .keyword_or,
            .keyword_raise,
            .keyword_struct,
            .keyword_then,
            .keyword_trait,
            .keyword_try,
            .keyword_using,
            .keyword_var,
            .keyword_when,
            .keyword_while,
            .keyword_with,
            .plus,
            .minus,
            .star,
            .star_star,
            .slash,
            .slash_slash,
            .percent,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .slash_slash_equal,
            .equal,
            .equal_equal,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .left_paren,
            .left_bracket,
            .left_brace,
            .comma,
            .colon,
            .dot,
            .dot_dot,
            .dot_dot_less,
            .question_dot,
            .fat_arrow,
            .at,
            .newline,
            .eof,
            => false,
        };
    }

    /// The spelling used when naming this kind in a diagnostic, in the user's
    /// vocabulary rather than the implementation's.
    pub fn describe(kind: Kind) []const u8 {
        return switch (kind) {
            .int_literal => "a whole number",
            .float_literal => "a decimal number",
            .string_literal, .raw_string_literal, .multiline_string_literal => "a string",
            .string_start, .string_middle, .string_end => "a string",
            .identifier => "a name",
            .doc_comment => "a documentation comment",
            .newline => "the end of the line",
            .eof => "the end of the file",
            .invalid => "unrecognized text",
            else => kind.lexeme() orelse "a token",
        };
    }

    /// The fixed source spelling of a kind that has one, or null when the kind's
    /// text varies.
    pub fn lexeme(kind: Kind) ?[]const u8 {
        return switch (kind) {
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .multiline_string_literal,
            .string_start,
            .string_middle,
            .string_end,
            .identifier,
            .doc_comment,
            .newline,
            .eof,
            .invalid,
            => null,

            .keyword_and => "and",
            .keyword_assert => "assert",
            .keyword_break => "break",
            .keyword_case => "case",
            .keyword_catch => "catch",
            .keyword_class => "class",
            .keyword_const => "const",
            .keyword_constructor => "constructor",
            .keyword_continue => "continue",
            .keyword_else => "else",
            .keyword_enum => "enum",
            .keyword_extends => "extends",
            .keyword_false => "false",
            .keyword_finally => "finally",
            .keyword_for => "for",
            .keyword_func => "func",
            .keyword_if => "if",
            .keyword_in => "in",
            .keyword_is => "is",
            .keyword_not => "not",
            .keyword_nothing => "nothing",
            .keyword_or => "or",
            .keyword_raise => "raise",
            .keyword_return => "return",
            .keyword_self => "self",
            .keyword_struct => "struct",
            .keyword_super => "super",
            .keyword_then => "then",
            .keyword_trait => "trait",
            .keyword_true => "true",
            .keyword_try => "try",
            .keyword_using => "using",
            .keyword_var => "var",
            .keyword_when => "when",
            .keyword_while => "while",
            .keyword_with => "with",

            .plus => "+",
            .minus => "-",
            .star => "*",
            .star_star => "**",
            .slash => "/",
            .slash_slash => "//",
            .percent => "%",
            .plus_equal => "+=",
            .minus_equal => "-=",
            .star_equal => "*=",
            .slash_equal => "/=",
            .slash_slash_equal => "//=",
            .equal => "=",
            .equal_equal => "==",
            .bang_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .left_paren => "(",
            .right_paren => ")",
            .left_bracket => "[",
            .right_bracket => "]",
            .left_brace => "{",
            .right_brace => "}",
            .comma => ",",
            .colon => ":",
            .dot => ".",
            .dot_dot => "..",
            .dot_dot_less => "..<",
            .question => "?",
            .question_dot => "?.",
            .fat_arrow => "=>",
            .at => "@",
            .underscore => "_",
        };
    }
};

/// Section 3.4 keeps keywords reserved everywhere, including after `.`, so this
/// table is consulted for every identifier.
///
/// `get`, `set`, and `value` are deliberately absent. They are meaningful only
/// inside a property body (section 10.3), and reserving them everywhere would
/// forbid ordinary names for no benefit.
pub const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "and", .keyword_and },
    .{ "assert", .keyword_assert },
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "catch", .keyword_catch },
    .{ "class", .keyword_class },
    .{ "const", .keyword_const },
    .{ "constructor", .keyword_constructor },
    .{ "continue", .keyword_continue },
    .{ "else", .keyword_else },
    .{ "enum", .keyword_enum },
    .{ "extends", .keyword_extends },
    .{ "false", .keyword_false },
    .{ "finally", .keyword_finally },
    .{ "for", .keyword_for },
    .{ "func", .keyword_func },
    .{ "if", .keyword_if },
    .{ "in", .keyword_in },
    .{ "is", .keyword_is },
    .{ "not", .keyword_not },
    .{ "nothing", .keyword_nothing },
    .{ "or", .keyword_or },
    .{ "raise", .keyword_raise },
    .{ "return", .keyword_return },
    .{ "self", .keyword_self },
    .{ "struct", .keyword_struct },
    .{ "super", .keyword_super },
    .{ "then", .keyword_then },
    .{ "trait", .keyword_trait },
    .{ "true", .keyword_true },
    .{ "try", .keyword_try },
    .{ "using", .keyword_using },
    .{ "var", .keyword_var },
    .{ "when", .keyword_when },
    .{ "while", .keyword_while },
    .{ "with", .keyword_with },
});

const testing = std.testing;

test "every kind is classified for the continuation rule" {
    // The switch in canEndExpression is exhaustive, so this only guards the
    // handful of classifications that are easy to get backwards.
    try testing.expect(Kind.identifier.canEndExpression());
    try testing.expect(Kind.int_literal.canEndExpression());
    try testing.expect(Kind.right_paren.canEndExpression());
    try testing.expect(Kind.keyword_return.canEndExpression());

    try testing.expect(!Kind.plus.canEndExpression());
    try testing.expect(!Kind.comma.canEndExpression());
    try testing.expect(!Kind.dot.canEndExpression());
    try testing.expect(!Kind.keyword_and.canEndExpression());
    try testing.expect(!Kind.left_paren.canEndExpression());
}

test "keywords and identifiers are distinguished" {
    try testing.expectEqual(Kind.keyword_var, keywords.get("var").?);
    try testing.expectEqual(Kind.keyword_nothing, keywords.get("nothing").?);
    try testing.expect(keywords.get("get") == null);
    try testing.expect(keywords.get("set") == null);
    try testing.expect(keywords.get("value") == null);
    try testing.expect(keywords.get("score") == null);
}
