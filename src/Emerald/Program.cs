using Emerald;

// The CLI (§3.5). v0 supports new / run / check; build, ship, test, fmt, and explain
// come later.

if (args.Length == 0)
{
    Console.WriteLine("""
        emerald — v0 prototype

          emerald new <name>        start a project
          emerald run <file.em>     run a program
          emerald check <file.em>   look for problems without running
          emerald <file.em>         same as run

        Every .em file beside the entry file is part of the project — no imports needed.
        """);
    return 0;
}

if (args[0] == "new") return Commands.New(args[1..]);
if (args[0] == "check") return Commands.Check(args[1..]);

string path = args[0] == "run" ? args.ElementAtOrDefault(1) ?? "" : args[0];

if (string.IsNullOrWhiteSpace(path))
{
    Console.Error.WriteLine("emerald run needs a file.");
    return 64;
}

if (!File.Exists(path))
{
    Console.Error.WriteLine($"No file named {path}.");
    return 66;
}

string entryName = Path.GetFileName(path);

var project = new Project(path);
var program = project.Load();
var problems = project.Diagnostics;

// Only type-check code that parsed. Checking a broken tree produces cascades, and
// §3.6 says one error per cause.
if (problems.Count == 0)
{
    var checker = new Checker(entryName, project.FileOf);
    checker.Check(program);
    problems = checker.Diagnostics;
}

if (problems.Count > 0)
{
    Reporter.Report(problems, project);
    return 65;
}

try
{
    new Interpreter().Run(program);
    return 0;
}
catch (ExitSignal stop)
{
    // `exit` is an ordinary way for a program to finish, not an error.
    return stop.Code;
}
catch (RuntimeError error)
{
    // Runtime diagnostics use the same voice as compile-time ones (§3.6): the subject
    // is the program, never the programmer, and no "fatal" or "invalid".
    Reporter.RuntimeFailure(error, entryName, project);
    return 70;
}
