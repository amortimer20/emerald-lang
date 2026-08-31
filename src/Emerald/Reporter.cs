namespace Emerald;

/// <summary>
/// Renders diagnostics for a terminal (§3.6). Shared by <c>run</c> and <c>check</c> so
/// the two cannot drift — an error should read the same however you provoked it.
/// </summary>
public static class Reporter
{
    /// <summary>
    /// One error per cause: report the first and count the rest. A terminal is read top
    /// to bottom, so a wall of cascading errors buries the one that matters.
    /// </summary>
    public static void Report(List<Diagnostic> problems, Project project)
    {
        if (problems.Count == 0) return;
        var first = problems[0];

        Console.Error.WriteLine();
        Console.Error.WriteLine($"{first.File}:{first.Line}  {first.Message}");
        Quote(project.LinesOf(first.File), first.Line);

        if (first.Hint is not null)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine($"  {first.Hint}");
        }

        if (problems.Count > 1)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine(
                $"  {problems.Count - 1} further error(s) suppressed — likely caused by this one.");
        }

        Console.Error.WriteLine();
    }

    public static void RuntimeFailure(RuntimeError error, string fileName, Project project)
    {
        Console.Error.WriteLine();
        Console.Error.WriteLine($"{fileName}:{error.Line}  {error.Message}");
        Quote(project.LinesOf(fileName), error.Line);

        if (error.Hint is not null)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine($"  {error.Hint}");
        }
        Console.Error.WriteLine();
    }

    private static void Quote(string[] lines, int line)
    {
        if (line <= 0 || line - 1 >= lines.Length) return;

        string text = lines[line - 1];
        if (text.Trim().Length == 0) return;

        Console.Error.WriteLine();
        Console.Error.WriteLine($"  {line,3} | {text.TrimEnd()}");
    }
}
