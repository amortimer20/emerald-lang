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
/// a token knows its line and not its column. The cost is that spacing is normalised: what
/// comes back is what the formatter would have written, not what was typed. For a
/// diagnostic that is arguably better, and it is the same normalising a formatter does.
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
}
