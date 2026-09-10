using System.Text;

namespace Emerald;

/// <summary>
/// An expression, written back out as source.
///
/// This exists because <c>assert</c> has to report the code rather than the value: a
/// function receives <c>false</c> and can say nothing more, which is the whole reason
/// §3.8 filed assert as a macro demand. Rendering from the tree gets the same result
/// without a macro system.
///
/// Rendered rather than quoted from the original text, because the parser keeps no spans —
/// a token knows its line and not its column. The cost is that spacing is normalized: what
/// comes back is what the formatter would have written, not what was typed. For a
/// diagnostic that is arguably better, and it is the same normalizing a formatter does.
///
/// §3.5 wants generated code visible in a synthetic source document. This is the half of
/// that which does not need a code generator.
/// </summary>
public static class Source
{
    public static string Of(Expr expr) => expr switch
    {
        Expr.Literal l => Literal(l.Value),
        Expr.Interpolation i => Interpolated(i),
        Expr.Variable v => v.Name.Lexeme,
        Expr.Grouping g => $"({Of(g.Inner)})",

        // `not x` takes a space where `-x` does not, which is the difference between a
        // word and a symbol rather than anything deeper.
        Expr.Unary u => u.Op.Type == TokenType.Not
            ? $"not {Of(u.Right)}"
            : $"{u.Op.Lexeme}{Of(u.Right)}",

        Expr.Binary b => $"{Of(b.Left)} {b.Op.Lexeme} {Of(b.Right)}",
        Expr.Logical l => $"{Of(l.Left)} {l.Op.Lexeme} {Of(l.Right)}",
        Expr.IfExpr i => $"if {Of(i.Condition)} then {Of(i.Then)} else {Of(i.Else)}",
        Expr.RangeExpr r => $"{Of(r.Start)}..{Of(r.End)}",
        Expr.ListLiteral a => $"[{Join(a.Items)}]",

        Expr.DictLiteral d => d.Entries.Count == 0
            ? "[:]"
            : "[" + string.Join(", ", d.Entries.Select(e => $"{Of(e.Key)}: {Of(e.Value)}")) + "]",

        Expr.Index x => $"{Of(x.Target)}[{Of(x.Position)}]",
        Expr.Get g => $"{Of(g.Target)}{(g.Optional ? "?." : ".")}{g.Name.Lexeme}",
        Expr.Lambda l => Lambda(l),
        Expr.Call c => Call(c),
        _ => "..."
    };

    private static string Call(Expr.Call c)
    {
        // A bare `list.count` parses as a Get, so anything reaching here was written with
        // parentheses or a block — and printing them back is what was written.
        string callee = Of(c.Callee);
        string args = c.Args.Count == 0 && c.Trailing is not null ? "" : $"({Join(c.Args)})";
        string block = c.Trailing is null ? "" : $" {Lambda(c.Trailing)}";
        return callee + args + block;
    }

    private static string Lambda(Expr.Lambda l)
    {
        string parameters = l.Params.Count == 0
            ? ""
            : string.Join(", ", l.Params.Select(p => p.Name.Lexeme)) + " => ";

        // A lambda body is statements, and statements do not render — one expression is
        // the shape a diagnostic will almost always be showing, so it is the shape given.
        string body = l.Body is [Stmt.ExprStmt only] ? Of(only.Expression) : "...";
        return $"{{ {parameters}{body} }}";
    }

    private static string Interpolated(Expr.Interpolation i)
    {
        var text = new StringBuilder("\"");

        foreach (var part in i.Parts)
        {
            if (part is Expr.Literal { Value: string raw }) text.Append(Escaped(raw));
            else text.Append("#{").Append(Of(part)).Append('}');
        }

        return text.Append('"').ToString();
    }

    private static string Literal(object? value) => value switch
    {
        null => "nothing",
        bool b => b ? "true" : "false",
        string s => $"\"{Escaped(s)}\"",
        _ => Builtins.Display(value),
    };

    /// <summary>
    /// Puts back what the scanner took out, so a rendered string can be pasted into a
    /// program and mean the same thing.
    /// </summary>
    private static string Escaped(string text) => text
        .Replace("\\", "\\\\")
        .Replace("\"", "\\\"")
        .Replace("\n", "\\n")
        .Replace("\t", "\\t")
        .Replace("#{", "\\#{");

    private static string Join(List<Expr> items) => string.Join(", ", items.Select(Of));

    /// <summary>
    /// Where a piece of syntax begins. Lives here rather than in the checker because two
    /// passes now need it: the indentation rule, and putting a module file's statements
    /// back in order after §3.3 has split them into members and an initializer.
    /// </summary>
    public static int LineOf(Expr expr) => expr switch
    {
        Expr.Variable v => v.Name.Line,
        Expr.Binary b => b.Op.Line,
        Expr.Logical l => l.Op.Line,
        Expr.Unary u => u.Op.Line,
        Expr.Get g => g.Name.Line,
        Expr.Call c => LineOf(c.Callee),
        Expr.Grouping g => LineOf(g.Inner),
        Expr.Literal l => l.Line,
        Expr.Index x => x.Bracket.Line,
        Expr.ListLiteral l => l.Bracket.Line,
        Expr.DictLiteral d => d.Bracket.Line,
        Expr.RangeExpr r => LineOf(r.Start),

        // An if expression's own line is its condition's, falling through to the branches
        // when the condition carries nothing — every part of it can be a bare literal.
        Expr.IfExpr i => FirstLine(LineOf(i.Condition), LineOf(i.Then), LineOf(i.Else)),
        Expr.Interpolation p => p.Parts.Select(LineOf).FirstOrDefault(n => n > 0),
        _ => 0
    };

    /// <summary>Where a statement begins, for the indentation check. Zero means the shape
    /// carries no usable token, and the statement is simply skipped.</summary>
    public static int LineOf(Stmt stmt) => stmt switch
    {
        Stmt.VarDecl v => v.Name.Line,
        Stmt.Assign a => a.Op.Line,
        Stmt.ExprStmt e => LineOf(e.Expression),
        Stmt.If i => LineOf(i.Condition),
        Stmt.While w => LineOf(w.Condition),
        Stmt.For f => f.Variable.Line,
        Stmt.FuncDecl fn => fn.Name.Line,
        Stmt.ClassDecl c => c.Name.Line,
        Stmt.ConstructorDecl c => c.Keyword.Line,
        Stmt.Return r => r.Keyword.Line,
        Stmt.Throw t => t.Keyword.Line,
        Stmt.Assert a => a.Keyword.Line,
        Stmt.TryCatch t => t.Keyword.Line,
        Stmt.Break b => b.Keyword.Line,
        Stmt.Continue c => c.Keyword.Line,
        _ => 0
    };

    private static int FirstLine(params int[] lines) => lines.FirstOrDefault(n => n > 0);

}
