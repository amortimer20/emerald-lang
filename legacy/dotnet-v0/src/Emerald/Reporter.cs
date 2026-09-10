namespace Emerald;

/// <summary>
/// Renders diagnostics for a terminal (§3.6). Shared by <c>run</c> and <c>check</c> so
/// the two cannot drift — an error should read the same however you provoked it.
/// </summary>
public static class Reporter
{
    public static bool HasErrors(List<Diagnostic> problems) =>
        problems.Any(d => d.Severity == Severity.Error);

    /// <summary>
    /// Warnings first, then the errors — every warning, but only the first error.
    ///
    /// The asymmetry is the point. Cascade suppression exists because one typo producing
    /// forty errors buries the one that matters (§3.6), and that reasoning is about
    /// <em>errors</em>: they descend from one another, so the later ones are usually
    /// noise. Warnings are independent findings about separate lines, and suppressing
    /// them would hide teaching the compiler had already done.
    /// </summary>
    public static void Report(List<Diagnostic> problems, Project project)
    {
        // Both callers already check, but this method is public and indexes problems[0]
        // below. A guard that costs nothing beats one that lives in every caller.
        if (problems.Count == 0) return;

        foreach (var warning in problems.Where(d => d.Severity == Severity.Warning))
            Write(warning, project, "warning: ");

        var errors = problems.Where(d => d.Severity == Severity.Error).ToList();

        // The topic of whatever is about to be reported, so `emerald explain` needs no
        // argument. A warning counts when nothing worse happened — it is still the last
        // thing the compiler said.
        Explanations.Remember(
            (errors.Count > 0 ? errors[0] : problems[0]).Topic);

        if (errors.Count == 0) return;

        Write(errors[0], project, "");

        if (errors[0].Topic is not null)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine("  emerald explain");
        }

        if (errors.Count > 1)
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine(
                $"  {errors.Count - 1} further error(s) suppressed — likely caused by this one.");
        }

        Console.Error.WriteLine();
    }

    private static void Write(Diagnostic d, Project project, string label)
    {
        Console.Error.WriteLine();
        Console.Error.WriteLine($"{d.File}:{d.Line}  {label}{d.Message}");
        Quote(project.LinesOf(d.File), d.Line);

        if (d.Hint is not null)
        {
            Console.Error.WriteLine();
            WriteHint(d.Hint);
        }
    }

    public static void RuntimeFailure(RuntimeError error, string fileName, Project project)
    {
        // No runtime failure carries a topic yet, but it is still the last thing the
        // compiler said. Forgetting the previous one keeps `emerald explain` from
        // answering a crash with an explanation of an unrelated compile-time mistake.
        Explanations.Remember(null);

        Console.Error.WriteLine();
        Console.Error.WriteLine($"{fileName}:{error.Line}  {error.Message}");
        Quote(project.LinesOf(fileName), error.Line);

        if (error.Hint is not null)
        {
            Console.Error.WriteLine();
            WriteHint(error.Hint);
        }
        Console.Error.WriteLine();
    }

    /// <summary>
    /// Every line of a hint, indented. Only the first used to be, so a hint that spanned
    /// lines came out ragged unless whoever wrote the string had remembered to put the
    /// spaces in themselves — which some had and some had not, and the difference was
    /// invisible until two of them appeared side by side.
    /// </summary>
    private static void WriteHint(string hint)
    {
        foreach (string line in hint.Replace("\r\n", "\n").Split('\n'))
            Console.Error.WriteLine($"  {line.TrimStart()}");
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
