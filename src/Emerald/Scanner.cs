using System.Text;

namespace Emerald;

/// <summary>
/// Source text -> tokens. Also applies Emerald's newline rules (§3.1): a newline ends a
/// statement unless the line is obviously unfinished, or the next line continues it.
/// </summary>
public sealed class Scanner(string source, string fileName)
{
    private static readonly Dictionary<string, TokenType> Keywords = new()
    {
        ["var"] = TokenType.Var,        ["const"] = TokenType.Const,
        ["func"] = TokenType.Func,      ["return"] = TokenType.Return,
        ["if"] = TokenType.If,          ["then"] = TokenType.Then,
        ["else"] = TokenType.Else,      ["while"] = TokenType.While,
        ["unless"] = TokenType.Unless,  ["until"] = TokenType.Until,
        ["for"] = TokenType.For,        ["in"] = TokenType.In,
        ["and"] = TokenType.And,        ["or"] = TokenType.Or,
        ["not"] = TokenType.Not,        ["true"] = TokenType.True,
        ["false"] = TokenType.False,    ["nothing"] = TokenType.Nothing,

        ["class"] = TokenType.Class,       ["trait"] = TokenType.Trait,
        ["struct"] = TokenType.Struct,     ["abstract"] = TokenType.Abstract,
        ["enum"] = TokenType.Enum,
        ["static"] = TokenType.Static,
        ["throw"] = TokenType.Throw,       ["try"] = TokenType.Try,
        ["catch"] = TokenType.Catch,
        ["break"] = TokenType.Break,      ["continue"] = TokenType.Continue,
        ["assert"] = TokenType.Assert,
        ["extends"] = TokenType.Extends,
        ["with"] = TokenType.With,      ["constructor"] = TokenType.Constructor,

        // Deliberately NOT a keyword: `self` stays an ordinary identifier, so `self.name`
        // is plain member access and needs no special node anywhere downstream.
    };

    private readonly List<Token> _tokens = [];
    private int _start;
    private int _current;
    private int _line = 1;

    public List<Diagnostic> Diagnostics { get; } = [];

    /// <summary>
    /// First and last line of each multi-line <c>#[ ]#</c> comment. The formatter needs
    /// these: what is inside a block comment is freeform text — a diagram, a pasted
    /// sample — and re-indenting it destroys the only thing its layout was for. Recorded
    /// here rather than found again later, since finding them means repeating the nesting
    /// and string rules this scanner already has.
    /// </summary>
    public List<(int From, int To)> BlockComments { get; } = [];

    public List<Token> ScanTokens()
    {
        while (!AtEnd)
        {
            _start = _current;
            ScanToken();
        }
        Add(TokenType.Eof, "");
        return ApplyNewlineRules(_tokens);
    }

    private void ScanToken()
    {
        char c = Advance();
        switch (c)
        {
            case ' ' or '\r' or '\t': break;

            case '\n':
                Add(TokenType.Newline, "\\n");
                _line++;
                break;

            case '#': Comment(); break;
            case '"': StringLiteral(); break;

            case '(': Add(TokenType.LeftParen, "("); break;
            case ')': Add(TokenType.RightParen, ")"); break;
            case '{': Add(TokenType.LeftBrace, "{"); break;
            case '}': Add(TokenType.RightBrace, "}"); break;
            case '[': Add(TokenType.LeftBracket, "["); break;
            case ']': Add(TokenType.RightBracket, "]"); break;
            case ',': Add(TokenType.Comma, ","); break;
            case ':': Add(TokenType.Colon, ":"); break;
            case '@': Add(TokenType.At, "@"); break;

            // A '?' glued to an identifier is folded into it by ScanIdentifier — that is how
            // predicate names and String? both work. One standing alone is the nullable
            // marker after a closing '>', as in List<Int>?, unless a '.' follows it.
            case '?': Add(Match('.') ? TokenType.QuestionDot : TokenType.Question, Text); break;

            case '.':
                Add(Match('.') ? TokenType.DotDot : TokenType.Dot, Match2());
                break;

            case '+': Add(Match('=') ? TokenType.PlusAssign : TokenType.Plus, Match2()); break;
            case '-': Add(Match('=') ? TokenType.MinusAssign : TokenType.Minus, Match2()); break;
            case '*':
                if (Match('*')) Add(TokenType.StarStar, "**");
                else Add(Match('=') ? TokenType.StarAssign : TokenType.Star, Match2());
                break;
            case '%': Add(TokenType.Percent, "%"); break;

            case '/':
                if (Match('/')) Add(TokenType.SlashSlash, "//");
                else Add(Match('=') ? TokenType.SlashAssign : TokenType.Slash, Match2());
                break;

            case '=':
                if (Match('>')) Add(TokenType.Arrow, "=>");
                else if (Match('=')) Add(TokenType.Equal, "==");
                else Add(TokenType.Assign, "=");
                break;

            case '!':
                if (Match('=')) Add(TokenType.NotEqual, "!=");
                else Error($"Emerald has no '!' operator — use 'not'.");
                break;

            case '<': Add(Match('=') ? TokenType.LessEqual : TokenType.Less, Match2()); break;
            case '>': Add(Match('=') ? TokenType.GreaterEqual : TokenType.Greater, Match2()); break;

            default:
                if (char.IsAsciiDigit(c)) Number();
                else if (IsIdentStart(c)) Identifier();
                else Error($"Unexpected character '{c}'.");
                break;
        }
    }

    // ---- comments -------------------------------------------------------

    private void Comment()
    {
        if (Peek() == '[')            // #[ ... ]# block, nesting
        {
            int opened = _line;
            Advance();
            int depth = 1;
            while (!AtEnd && depth > 0)
            {
                if (Peek() == '#' && PeekNext() == '[') { Advance(); Advance(); depth++; }
                else if (Peek() == ']' && PeekNext() == '#') { Advance(); Advance(); depth--; }
                else { if (Peek() == '\n') _line++; Advance(); }
            }
            if (depth > 0) Error("This block comment is never closed.");
            else if (_line > opened) BlockComments.Add((opened, _line));
        }
        else                          // # line and ## doc comments
        {
            while (!AtEnd && Peek() != '\n') Advance();
        }
    }

    // ---- literals -------------------------------------------------------

    private void StringLiteral()
    {
        var raw = new StringBuilder();

        // Inside #{ }, the text is an expression, not string content — so a quote there
        // belongs to a nested string rather than ending this one. Without tracking that,
        // "#{names.join(\", \")}" terminates at the comma's quote.
        int interpolation = 0;

        while (!AtEnd)
        {
            char c = Peek();
            if (c == '"' && interpolation == 0) break;
            Advance();

            if (c == '\n') { _line++; raw.Append(c); continue; }

            // Escapes are string-level; inside an interpolation the nested scanner
            // handles them, so pass those through untouched.
            if (c == '\\' && interpolation == 0 && !AtEnd)
            {
                raw.Append(Advance() switch
                {
                    'n' => "\n", 't' => "\t", '"' => "\"",
                    '\\' => "\\\\",

                    // These two stay escaped. Interpolation is split later, in the parser,
                    // and by then a bare # is indistinguishable from one written \# to mean
                    // a literal — which is why \#{name} used to interpolate anyway. The
                    // backslash before a backslash survives for the same reason: it is what
                    // stops "\\#{n}" from being read as an escaped hash.
                    '#' => "\\#",

                    var other => other.ToString()
                });
                continue;
            }

            if (c == '#' && Peek() == '{')
            {
                raw.Append(c).Append(Advance());
                interpolation++;
                continue;
            }

            if (interpolation > 0)
            {
                if (c == '{') interpolation++;
                else if (c == '}') interpolation--;
                else if (c == '"')
                {
                    // Copy a nested string wholesale; the nested scanner will re-read it.
                    raw.Append(c);
                    while (!AtEnd && Peek() != '"')
                    {
                        if (Peek() == '\\') raw.Append(Advance());
                        if (!AtEnd) raw.Append(Advance());
                    }
                    if (!AtEnd) raw.Append(Advance());
                    continue;
                }
            }

            raw.Append(c);
        }

        if (AtEnd)
        {
            Error(interpolation > 0
                ? "This #{ } is never closed."
                : "This string is never closed.");
            return;
        }

        Advance();  // closing quote

        // The raw text still contains its #{...} markers. The parser resolves those,
        // because their contents are full expressions and need the real parser.
        Add(TokenType.String, "string", raw.ToString());
    }

    private void Number()
    {
        while (char.IsAsciiDigit(Peek())) Advance();

        // A '.' is a decimal point only when a digit follows it. That single guard is
        // what keeps `1..5` (a range) from lexing as `1.` and `.5` (two floats).
        if (Peek() == '.' && char.IsAsciiDigit(PeekNext()))
        {
            Advance();
            while (char.IsAsciiDigit(Peek())) Advance();
            Add(TokenType.Float, Text, double.Parse(Text));
            return;
        }

        Add(TokenType.Int, Text, long.Parse(Text));
    }

    private void Identifier()
    {
        while (IsIdentPart(Peek())) Advance();

        // A trailing '?' is part of a predicate method's name (§3.4) — unless a '.' follows
        // it, where it is the optional-chaining operator instead. One rule, stated once: a
        // '?' in a name is never immediately followed by a dot. The cost is that a
        // predicate cannot have a method called straight off it — `(n.even?).to_string()`
        // rather than `n.even?.to_string()` — which is why the checker explains that
        // spelling when the reading goes wrong.
        if (Peek() == '?' && PeekNext() != '.') Advance();

        string text = Text;
        Add(Keywords.TryGetValue(text, out var kw) ? kw : TokenType.Identifier, text);
    }

    // ---- newline rules (§3.1) -------------------------------------------

    /// <summary>
    /// Drops newlines that do not end a statement: after a token that leaves the line
    /// obviously unfinished, or before a token that continues the previous line.
    /// </summary>
    private static List<Token> ApplyNewlineRules(List<Token> tokens)
    {
        // Trailing operators, separators, and open brackets all mean "more is coming".
        HashSet<TokenType> unfinished =
        [
            TokenType.Plus, TokenType.Minus, TokenType.Star, TokenType.Slash, TokenType.Percent,
            TokenType.Assign, TokenType.PlusAssign, TokenType.MinusAssign,
            TokenType.StarAssign, TokenType.SlashAssign,
            TokenType.Equal, TokenType.NotEqual, TokenType.Less, TokenType.Greater,
            TokenType.LessEqual, TokenType.GreaterEqual,
            TokenType.And, TokenType.Or, TokenType.Not,
            TokenType.Comma, TokenType.Colon, TokenType.Dot, TokenType.DotDot, TokenType.Arrow,
            TokenType.LeftParen, TokenType.LeftBrace, TokenType.LeftBracket,
            TokenType.Newline,
        ];

        // A line starting with one of these continues the line above it.
        HashSet<TokenType> continues =
        [
            TokenType.Dot, TokenType.Else, TokenType.Then, TokenType.Catch,
            TokenType.RightBrace, TokenType.RightParen, TokenType.RightBracket,
        ];

        List<Token> result = [];
        foreach (var token in tokens)
        {
            if (token.Type == TokenType.Newline)
            {
                if (result.Count == 0) continue;
                if (unfinished.Contains(result[^1].Type)) continue;
            }
            result.Add(token);
        }

        // Second pass: drop a newline whose *next* real token continues the line.
        List<Token> final = [];
        for (int i = 0; i < result.Count; i++)
        {
            if (result[i].Type == TokenType.Newline &&
                i + 1 < result.Count &&
                continues.Contains(result[i + 1].Type))
                continue;
            final.Add(result[i]);
        }
        return final;
    }

    // ---- plumbing -------------------------------------------------------

    private bool AtEnd => _current >= source.Length;
    private string Text => source[_start.._current];
    private char Advance() => source[_current++];
    private char Peek() => AtEnd ? '\0' : source[_current];
    private char PeekNext() => _current + 1 >= source.Length ? '\0' : source[_current + 1];
    private string Match2() => Text;

    private bool Match(char expected)
    {
        if (AtEnd || source[_current] != expected) return false;
        _current++;
        return true;
    }

    private static bool IsIdentStart(char c) => char.IsAsciiLetter(c) || c == '_';
    private static bool IsIdentPart(char c) => char.IsAsciiLetterOrDigit(c) || c == '_';

    private void Add(TokenType type, string lexeme, object? literal = null) =>
        _tokens.Add(new Token(type, lexeme, literal, _line));

    private void Error(string message) =>
        Diagnostics.Add(new Diagnostic(fileName, _line, message));
}
