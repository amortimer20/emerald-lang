namespace Emerald;

/// <summary>
/// <c>emerald fmt</c> — one formatting, no configuration (§3.5). gofmt's innovation was
/// removing the argument, not the formatting.
///
/// A re-indenter rather than a pretty-printer, and deliberately so. Reprinting from the
/// syntax tree is how a formatter is usually built, but comments are not in the tree —
/// they are discarded by the scanner — so a tree-based formatter would silently delete
/// every comment in the file. That is not a trade worth making for tidier line breaks.
///
/// So this works on lines, and consults the token stream only to learn what a line's
/// braces really are. That distinction matters: <c>"#{count}"</c> contains a brace that is
/// not a brace, and a formatter counting characters would indent the rest of the file
/// wrongly from there on. The scanner already knows the difference, so it is asked.
/// </summary>
public static class Formatter
{
    private const string Indent = "    ";

    /// <summary>
    /// Returns the formatted text, or null if the source does not scan. A file with a
    /// broken string literal has no reliable brace structure, and guessing at one is how a
    /// formatter turns a small mistake into a mangled file.
    /// </summary>
    public static string? Format(string source)
    {
        string normalised = source.Replace("\r\n", "\n");

        var scanner = new Scanner(normalised, "<fmt>");
        var tokens = scanner.ScanTokens();
        if (scanner.Diagnostics.Count > 0) return null;

        // Which real tokens sit on each line. A line that is only a comment has none,
        // which is right: it takes the indentation of wherever it sits.
        Dictionary<int, List<Token>> byLine = [];
        foreach (var token in tokens)
        {
            if (token.Type is TokenType.Newline or TokenType.Eof) continue;
            if (!byLine.TryGetValue(token.Line, out var list)) byLine[token.Line] = list = [];
            list.Add(token);
        }

        string[] lines = normalised.Split('\n');
        List<string> output = [];
        int depth = 0;

        // Lines strictly inside a multi-line block comment, which are left exactly as
        // written. A diagram or a pasted sample in there has layout that means something,
        // and this formatter's whole justification is not destroying what it cannot read.
        HashSet<int> verbatim = [];
        foreach (var (from, to) in scanner.BlockComments)
            for (int line = from + 1; line < to; line++) verbatim.Add(line);

        for (int i = 0; i < lines.Length; i++)
        {
            if (verbatim.Contains(i + 1))
            {
                output.Add(lines[i].TrimEnd());
                continue;
            }

            string text = lines[i].Replace("\t", Indent).Trim();
            var here = byLine.GetValueOrDefault(i + 1, []);

            if (text.Length == 0)
            {
                output.Add("");
                continue;
            }

            // A line beginning with a closer belongs one level out — it ends the block
            // rather than sitting inside it.
            int lead = here.Count > 0 && IsCloser(here[0].Type) ? 1 : 0;
            int indent = Math.Max(0, depth - lead);

            // `} else {` is the one brace placement §3.1 names, and the one people
            // actually get wrong. Split only when the `}` opens the line, where the first
            // character is known to be that token and the cut is unambiguous.
            if (here.Count >= 2
                && here[0].Type == TokenType.RightBrace
                && here[1].Type == TokenType.Else)
            {
                output.Add(Repeat(indent) + "}");
                text = text[1..].TrimStart();
                depth += Delta(here.Take(1));
                here = [.. here.Skip(1)];
                indent = Math.Max(0, depth);
            }

            output.Add(Repeat(indent) + text);
            depth += Delta(here);
        }

        // Exactly one trailing newline. Git, diffs, and every POSIX tool expect a file to
        // end with one, and .gitattributes already pins line endings for the same reason.
        while (output.Count > 0 && output[^1].Length == 0) output.RemoveAt(output.Count - 1);
        return string.Join("\n", output) + "\n";
    }

    private static int Delta(IEnumerable<Token> tokens)
    {
        int change = 0;
        foreach (var token in tokens)
        {
            if (IsOpener(token.Type)) change++;
            else if (IsCloser(token.Type)) change--;
        }
        return change;
    }

    private static bool IsOpener(TokenType type) =>
        type is TokenType.LeftBrace or TokenType.LeftBracket or TokenType.LeftParen;

    private static bool IsCloser(TokenType type) =>
        type is TokenType.RightBrace or TokenType.RightBracket or TokenType.RightParen;

    private static string Repeat(int depth) => string.Concat(Enumerable.Repeat(Indent, depth));
}
