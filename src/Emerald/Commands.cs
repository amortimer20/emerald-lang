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

                    // The editor needs this to pick a squiggle color, and lowercase
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
    /// <c>emerald test</c> — <c>*_test.em</c> files and <c>@test</c> functions (§3.5).
    /// Convention over configuration, in the box: nothing to register and nothing to
    /// configure, so a test is written by naming a file and marking a function.
    ///
    /// A test fails by returning false or by throwing — and `assert` throws, carrying the
    /// expression it was given rather than only the false it produced (§3.5).
    /// </summary>
    public static int Test(string[] args)
    {
        string path = args.FirstOrDefault(a => !a.StartsWith('-')) ?? ".";

        if (!Directory.Exists(path))
        {
            Console.Error.WriteLine($"No directory named {path}.");
            return 66;
        }

        var testFiles = Directory.EnumerateFiles(path, "*_test.em", SearchOption.AllDirectories)
                                 .OrderBy(p => p, StringComparer.Ordinal)
                                 .ToList();

        if (testFiles.Count == 0)
        {
            Console.WriteLine($"No *_test.em files under {path}.");
            Console.WriteLine();
            Console.WriteLine("  A test is a file named something_test.em with @test functions in it.");
            return 0;
        }

        // A directory is a project (§3.3), so loading any file in it loads the rest —
        // including whatever the tests are testing.
        string entry = File.Exists(Path.Combine(path, "main.em"))
            ? Path.Combine(path, "main.em")
            : testFiles[0];

        var project = new Project(entry);
        var program = project.Load();
        var problems = project.Diagnostics;

        if (problems.Count == 0)
        {
            var checker = new Checker(Path.GetFileName(entry), project.FileOf, project.LinesOf);
            checker.Check(program);
            problems = checker.Diagnostics;
        }

        if (problems.Count > 0)
        {
            Reporter.Report(problems, project);
            if (Reporter.HasErrors(problems)) return 65;
        }

        // A test in a file that declares no type became a static method on a class named
        // after the file (§3.3), so both shapes have to be looked for.
        List<(string? Owner, string Name)> tests = [];
        foreach (var stmt in program)
        {
            if (stmt is Stmt.FuncDecl fn && HasTestAttribute(fn))
                tests.Add((null, fn.Name.Lexeme));
            else if (stmt is Stmt.ClassDecl type)
                foreach (var member in type.Members.OfType<Stmt.FuncDecl>().Where(HasTestAttribute))
                    tests.Add((type.Name.Lexeme, member.Name.Lexeme));
        }

        if (tests.Count == 0)
        {
            Console.WriteLine($"Found {testFiles.Count} test file(s), but no @test functions in them.");
            Console.WriteLine();
            Console.WriteLine("  Mark one:  @test");
            Console.WriteLine("             func it_adds?(): Bool { return 1 + 1 == 2 }");
            return 0;
        }

        var interpreter = new Interpreter();
        interpreter.LoadDeclarations(program);

        int failed = 0;
        Console.WriteLine();

        foreach (var (owner, name) in tests)
        {
            string label = owner is null ? name : $"{owner}.{name}";

            try
            {
                object? result = interpreter.CallNamed(owner, name);

                // Returning nothing is a pass: a test that only throws on failure is a
                // perfectly good test, and demanding `return true` would be ceremony.
                if (result is false)
                {
                    Console.WriteLine($"  FAIL  {label}");
                    Detail("returned false");
                    failed++;
                }
                else Console.WriteLine($"  ok    {label}");
            }
            catch (ThrownError thrown)
            {
                Console.WriteLine($"  FAIL  {label}");
                Detail(thrown.Value.Message);
                failed++;
            }
            catch (RuntimeError error)
            {
                Console.WriteLine($"  FAIL  {label}");
                Detail(error.Message);
                failed++;
            }
        }

        Console.WriteLine();
        Console.WriteLine(failed == 0
            ? $"{Count(tests.Count, "test")}, all passing."
            : $"{Count(tests.Count, "test")}, {failed} failing.");

        return failed == 0 ? 0 : 1;
    }

    /// <summary>
    /// Indents every line of a failure, not only the first. An assertion's message runs to
    /// three lines, and leaving the continuations at the left margin made the detail look
    /// like it belonged to something else.
    /// </summary>
    private static void Detail(string message)
    {
        foreach (var line in message.Replace("\r\n", "\n").Split('\n'))
            Console.WriteLine($"        {line.TrimStart()}");
    }

    private static bool HasTestAttribute(Stmt.FuncDecl fn) =>
        fn.Attributes?.Any(a => a.Name.Lexeme == "test") ?? false;

    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n} {noun}s";

    /// <summary>
    /// <c>build</c>, <c>ship</c>, and <c>add</c> (§3.5) — named, specified, and not
    /// buildable yet, each for a concrete reason rather than for want of time.
    ///
    /// Reported rather than left as "unknown command", because where a command sits on the
    /// roadmap is useful information and a shrug is not. §2.6's argument about diagnostics
    /// applies to the tool as much as to the compiler.
    /// </summary>
    public static int NotYet(string command)
    {
        var (needs, instead) = command switch
        {
            "build" => ("a CIL backend — this compiler interprets rather than emits",
                        "emerald run main.em      runs it through the interpreter"),
            "ship" => ("a CIL backend, then .NET single-file publishing",
                       "emerald run main.em      runs it through the interpreter"),
            _ => ("a package registry to fetch from, and emerald.toml to record it in",
                  "every .em file beside yours is already part of the project — "
                  + "nothing to add for code you wrote"),
        };

        Console.Error.WriteLine($"emerald {command} needs {needs}.");
        Console.Error.WriteLine();
        Console.Error.WriteLine($"  {instead}");
        return 69;
    }

    /// <summary>
    /// <c>emerald fmt</c> — zero configuration, by design (§3.5). gofmt's innovation was
    /// removing the argument, not the formatting, so there is nothing here to set.
    ///
    /// A path may be a file or a directory; with no path, the current directory. Files
    /// that do not scan are reported and skipped rather than rewritten — a file with an
    /// unterminated string has no reliable brace structure, and a formatter guessing at
    /// one is how a small mistake becomes a mangled file.
    /// </summary>
    public static int Fmt(string[] args)
    {
        bool checkOnly = args.Contains("--check");
        string path = args.FirstOrDefault(a => !a.StartsWith('-')) ?? ".";

        List<string> files = [];
        if (File.Exists(path)) files.Add(path);
        else if (Directory.Exists(path))
            files.AddRange(Directory.EnumerateFiles(path, "*.em", SearchOption.AllDirectories)
                                    .OrderBy(p => p, StringComparer.Ordinal));
        else
        {
            Console.Error.WriteLine($"No file or directory named {path}.");
            return 66;
        }

        if (files.Count == 0)
        {
            Console.WriteLine($"No .em files under {path}.");
            return 0;
        }

        int changed = 0, skipped = 0;

        foreach (string file in files)
        {
            string original = File.ReadAllText(file);
            string? formatted = Formatter.Format(original);

            if (formatted is null)
            {
                Console.Error.WriteLine($"{Path.GetFileName(file)} — cannot be formatted "
                                        + "until it scans. Run emerald check on it.");
                skipped++;
                continue;
            }

            if (formatted == original.Replace("\r\n", "\n")) continue;

            changed++;
            if (checkOnly) Console.WriteLine($"{file} would change.");
            else File.WriteAllText(file, formatted);
        }

        if (checkOnly)
        {
            Console.WriteLine(changed == 0
                ? "Already formatted."
                : $"{changed} file(s) would change.");
        }
        else
        {
            Console.WriteLine(changed == 0
                ? "Already formatted."
                : $"Formatted {changed} file(s).");
        }

        // --check is for a build that should fail on unformatted code; formatting for
        // real has done its job either way.
        return checkOnly && changed > 0 ? 1 : skipped > 0 ? 65 : 0;
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
