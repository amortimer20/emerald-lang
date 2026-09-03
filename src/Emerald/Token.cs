namespace Emerald;

public enum TokenType
{
    // Literals and names
    Int, Float, String, Identifier,

    // Keywords
    Var, Const, Func, Return, If, Then, Else, While, For, In, Unless, Until,
    Class, Trait, Struct, Enum, Extends, With, Constructor, Abstract, Static,
    Throw, Try, Catch, Break, Continue, Assert,
    And, Or, Not, True, False, Nothing,

    // Punctuation
    LeftParen, RightParen, LeftBrace, RightBrace,
    LeftBracket, RightBracket,
    Comma, Colon, Dot, DotDot, Arrow, At, Question,

    // Operators
    Plus, Minus, Star, Slash, Percent, StarStar, SlashSlash,
    Assign, PlusAssign, MinusAssign, StarAssign, SlashAssign,
    Equal, NotEqual, Less, Greater, LessEqual, GreaterEqual,

    // Structure
    Newline, Eof
}

/// <summary>
/// One lexeme. <c>Literal</c> holds the decoded value for Int/Float tokens, and for
/// String tokens holds the raw inner text — interpolation is resolved later, in the
/// parser, because <c>"#{a + b}"</c> contains an expression that needs the full parser.
/// </summary>
public sealed record Token(TokenType Type, string Lexeme, object? Literal, int Line)
{
    public override string ToString() =>
        Type == TokenType.Newline ? "\\n" : $"{Type}('{Lexeme}')";
}
