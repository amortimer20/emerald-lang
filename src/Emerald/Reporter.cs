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
            Console.Error.WriteLine($"  {d.Hint}");
        }
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
