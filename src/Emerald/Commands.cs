using System.Text;
using System.Text.Json;

namespace Emerald;

/// <summary>CLI subcommands other than <c>run</c>.</summary>
public static class Commands
{
    /// <summary>
    /// <c>emerald check &lt;file&gt;</c> — scan, parse, and type-check without running.
    /// The editor needs this: finding a typo must not execute the program.
    ///
    /// <c>--json</c> emits every diagnostic as machine-readable output. The human form
    /// shows one error per cause (§3.6) because a terminal is read top to bottom; an
    /// editor shows squiggles inline, where several at once are useful rather than noisy.
    /// </summary>
    public static int Check(string[] args)
    {
        bool json = args.Contains("--json");
        string? path = args.FirstOrDefault(a => !a.StartsWith('-'));

        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            if (json) Console.WriteLine("""{"diagnostics":[]}""");
            else Console.Error.WriteLine($"No file named {path}.");
            return 66;
        }

        var project = new Project(path);
        var program = project.Load();
        var problems = project.Diagnostics;

        if (problems.Count == 0)
        {
            var checker = new Checker(Path.GetFileName(path), project.FileOf, project.LinesOf);
            checker.Check(program);
            problems = checker.Diagnostics;
        }

        if (json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                diagnostics = problems.Select(d => new
                {
                    file = d.File,
                    line = d.Line,
                    message = d.Message,
                    hint = d.Hint,

                    // The editor needs this to pick a squiggle colour, and lowercase
                    // because that is what every editor protocol already expects.
                    severity = d.Severity.ToString().ToLowerInvariant(),
                }),
            }));
            return 0;
        }

        if (problems.Count == 0)
        {
            Console.WriteLine($"{Path.GetFileName(path)} — no problems found.");
            return 0;
        }

        Reporter.Report(problems, project);

        // Warnings alone are not a failure — `emerald check` on a warned-about file
        // should still say the file is fit to run, because it is.
        if (!Reporter.HasErrors(problems))
        {
            Console.WriteLine($"{Path.GetFileName(path)} — no errors.");
            return 0;
        }

        return 65;
    }

    /// <summary>
    /// <c>emerald new my_game</c> — creates one file and nothing else (§3.5). No manifest,
    /// no src/, no .gitignore: emerald.toml appears the first time something needs it.
    /// A new project should be readable in full, which is the line-1 principle applied to
    /// projects rather than files.
    /// </summary>
    public static int New(string[] args)
    {
        string? name = args.FirstOrDefault(a => !a.StartsWith('-'));

        if (string.IsNullOrWhiteSpace(name))
        {
            Console.Error.WriteLine("emerald new needs a name:  emerald new my_game");
            return 64;
        }

        if (!IsUsableName(name))
        {
            Console.Error.WriteLine($"'{name}' will not work as a project name.");
            Console.Error.WriteLine();
            Console.Error.WriteLine("  Use letters, digits, and underscores, starting with a letter.");
            return 64;
        }

        if (Directory.Exists(name))
        {
            Console.Error.WriteLine($"There is already a directory named {name}.");
            Console.Error.WriteLine();
            Console.Error.WriteLine("  Pick another name, or delete it first.");
            return 73;
        }

        Directory.CreateDirectory(name);
        string entry = Path.Combine(name, "main.em");
        File.WriteAllText(entry, Starter(name));

        Console.WriteLine($"Created {name}/main.em");
        Console.WriteLine();
        Console.WriteLine($"  emerald run {name}/main.em");
        Console.WriteLine();
        Console.WriteLine("Every .em file you add beside it is part of the same project —");
        Console.WriteLine("there is nothing to import and nothing to configure.");
        return 0;
    }

    // $$ makes {{ }} the interpolation hole, so Emerald's own #{ } stays literal.
    private static string Starter(string name) =>
        $$"""
        # {{Title(name)}}

        print("Hello!")

        var name = read_line("What is your name? ")
        print("Nice to meet you, #{name}.")

        """;

    /// <summary>my_game -> My game — a heading, not a type name.</summary>
    private static string Title(string name)
    {
        var words = name.Replace('-', '_').Split('_', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return name;

        var result = new StringBuilder(char.ToUpperInvariant(words[0][0]) + words[0][1..]);
        foreach (var word in words.Skip(1)) result.Append(' ').Append(word);
        return result.ToString();
    }

    private static bool IsUsableName(string name) =>
        name.Length > 0
        && (char.IsAsciiLetter(name[0]) || name[0] == '_')
        && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-');
}
