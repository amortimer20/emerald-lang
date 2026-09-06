using System.Text;

namespace Emerald;

/// <summary>
/// <c>emerald repl</c> — §3.5 deferred this but kept it possible, and the two constraints
/// it named are what make it cheap now: a single statement parses standalone, and the
/// environment is an ordinary object rather than something the runtime hides.
///
/// The session is modeled as one file that keeps growing. Each entry is appended to the
/// accumulated source and its tokens shifted by the lines already there, so a diagnostic
/// quotes the right line without the REPL inventing its own numbering. Everything typed so
/// far is re-checked each time, which is quadratic and irrelevant: a session is tens of
/// lines, and it buys correct scoping with nothing to keep in sync.
/// </summary>
public static class Repl
{
    private const string FileName = "repl";

    public static int Run()
    {
        Console.WriteLine("Emerald. Type an expression to see it, :help for more.");
        Console.WriteLine();

        var interpreter = new Interpreter();
        List<string> lines = [];
        List<Stmt> history = [];

        while (true)
        {
            string? entry = ReadEntry();
            if (entry is null) break;
            if (entry.Trim().Length == 0) continue;

            if (entry.TrimStart().StartsWith(':'))
            {
                if (Command(entry.Trim(), history)) continue;
                break;
            }

            Enter(entry, lines, history, interpreter);
        }

        Console.WriteLine();
        return 0;
    }

    private static void Enter(
        string entry, List<string> lines, List<Stmt> history, Interpreter interpreter)
    {
        // Tokens are shifted past what has already been entered, so line numbers keep
        // running and a diagnostic can quote the accumulated source directly.
        int offset = lines.Count;
        var scanner = new Scanner(entry, FileName);
        var tokens = scanner.ScanTokens()
                            .Select(t => t with { Line = t.Line + offset })
                            .ToList();

        var parser = new Parser(tokens, FileName);
        var fresh = parser.ParseProgram();

        List<string> pending = [.. lines, .. entry.Replace("\r\n", "\n").TrimEnd('\n').Split('\n')];

        var problems = scanner.Diagnostics.Concat(parser.Diagnostics).ToList();

        if (problems.Count == 0)
        {
            // Redefining a name at a prompt replaces it, rather than colliding with what
            // was typed earlier — otherwise a second `func f` reads as an overload of the
            // first, and correcting a typo would be impossible.
            var replaced = history.Where(h => !Redefines(fresh, h)).ToList();

            var checker = new Checker(FileName, null, _ => [.. pending], interactive: true);
            checker.Check([.. replaced, .. fresh]);
            problems = checker.Diagnostics;

            // Everything typed so far is re-checked, so a diagnostic about an earlier
            // entry would be repeated at every prompt after it. Only the new lines report.
            problems = [.. problems.Where(d => d.Line > offset)];

            if (!problems.Any(d => d.Severity == Severity.Error))
            {
                Report(problems);
                lines.Clear();
                lines.AddRange(pending);
                history.Clear();
                history.AddRange(replaced);
                history.AddRange(fresh);

                try { interpreter.RunInteractive(fresh); }
                catch (ExitSignal) { throw; }
                catch (ThrownError thrown) { Failed(thrown.Value.Message); }
                catch (RuntimeError error) { Failed(error.Message); }

                return;
            }
        }

        // The entry is discarded, so nothing typed after it is checked against a state
        // that never existed.
        Report(problems);
    }

    /// <summary>Whether anything in the new entry declares a name this statement already
    /// declares — in which case the older one steps aside.</summary>
    private static bool Redefines(List<Stmt> fresh, Stmt older) =>
        DeclaredName(older) is { } name && fresh.Any(f => DeclaredName(f) == name);

    private static string? DeclaredName(Stmt stmt) => stmt switch
    {
        Stmt.FuncDecl f => f.Name.Lexeme,
        Stmt.ClassDecl c => c.Name.Lexeme,
        Stmt.EnumDecl e => e.Name.Lexeme,
        Stmt.VarDecl v => v.Name.Lexeme,
        _ => null,
    };

    /// <summary>
    /// Reads one entry, continuing while it is obviously unfinished. Brace depth is
    /// counted from the tokens rather than the characters, so a brace inside a string or a
    /// comment does not hold the prompt open forever.
    /// </summary>
    private static string? ReadEntry()
    {
        var entry = new StringBuilder();

        while (true)
        {
            Console.Write(entry.Length == 0 ? "> " : "  ");
            string? line = Console.ReadLine();

            if (line is null) return entry.Length == 0 ? null : entry.ToString();

            entry.AppendLine(line);
            string text = entry.ToString();

            if (Depth(text) <= 0) return text;
        }
    }

    private static int Depth(string text)
    {
        var scanner = new Scanner(text, FileName);
        var tokens = scanner.ScanTokens();

        // A file that does not scan cannot be measured — an unterminated string would
        // otherwise keep the prompt open with no way out.
        if (scanner.Diagnostics.Count > 0) return 0;

        int depth = 0;
        foreach (var token in tokens)
        {
            if (token.Type is TokenType.LeftBrace) depth++;
            else if (token.Type is TokenType.RightBrace) depth--;
        }

        return depth;
    }

    /// <summary>
    /// Every warning, then the first error — the same asymmetry §3.6 settles for a file.
    /// The line is not quoted back: the reader typed it a moment ago and can see it.
    /// </summary>
    private static void Report(List<Diagnostic> problems)
    {
        foreach (var warning in problems.Where(d => d.Severity == Severity.Warning))
            Write(warning, "warning: ");

        var errors = problems.Where(d => d.Severity == Severity.Error).ToList();
        if (errors.Count > 0) Write(errors[0], "");
    }

    private static void Write(Diagnostic d, string label)
    {
        Console.WriteLine($"  {label}{d.Message}");

        if (d.Hint is not null)
            foreach (var line in d.Hint.Split('\n'))
                Console.WriteLine($"    {line.TrimStart()}");
    }

    private static void Failed(string message)
    {
        foreach (var line in message.Replace("\r\n", "\n").Split('\n'))
            Console.WriteLine($"  {line.TrimStart()}");
    }

    /// <summary>Returns false to end the session.</summary>
    private static bool Command(string entry, List<Stmt> history)
    {
        switch (entry)
        {
            case ":quit" or ":q" or ":exit":
                return false;

            case ":help":
                Console.WriteLine("  Anything you can write in a file, plus:");
                Console.WriteLine();
                Console.WriteLine("    an expression on its own    prints what it comes to");
                Console.WriteLine("    :what                       what this session has defined");
                Console.WriteLine("    :quit                       leave, as does Ctrl+D");
                Console.WriteLine();
                Console.WriteLine("  A name defined again replaces the earlier one.");
                return true;

            case ":what":
            {
                var names = history.Select(DeclaredName).Where(n => n is not null).ToList();
                Console.WriteLine(names.Count == 0
                    ? "  Nothing yet."
                    : "  " + string.Join(", ", names));
                return true;
            }

            default:
                Console.WriteLine($"  No command {entry}. Try :help.");
                return true;
        }
    }
}
