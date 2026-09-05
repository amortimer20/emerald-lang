using Emerald;

// The CLI (§3.5). new, run, check, fmt, and explain are built; build, ship, test, and
// add come later.

if (args.Length == 0)
{
    Console.WriteLine("""
        emerald — v0 prototype

          emerald new <name>        start a project
          emerald run <file.em>     run a program
          emerald check <file.em>   look for problems without running
          emerald repl              try code a line at a time
          emerald test [path]       run every @test function
          emerald fmt [path]        format code, one way, no settings
          emerald explain           explain the last error
          emerald <file.em>         same as run

          build, ship, add          named, and not buildable yet — try one to see why

        Every .em file beside the entry file is part of the project — no imports needed.
        """);
    return 0;
}

if (args[0] == "new") return Commands.New(args[1..]);
if (args[0] == "check") return Commands.Check(args[1..]);
if (args[0] == "test") return Commands.Test(args[1..]);
if (args[0] is "repl" or "i") return Repl.Run();
if (args[0] == "fmt") return Commands.Fmt(args[1..]);
if (args[0] == "explain") return Explanations.Run(args[1..]);
if (args[0] is "build" or "ship" or "add") return Commands.NotYet(args[0]);

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
    var checker = new Checker(entryName, project.FileOf, project.LinesOf);
    checker.Check(program);
    problems = checker.Diagnostics;
}

// Warnings are printed and then stepped over. A warning that stopped the program would
// be an error wearing a softer word, and §2.6 wants the compiler teaching while the
// program still runs — otherwise every lesson arrives as an interruption.
if (problems.Count > 0)
{
    Reporter.Report(problems, project);
    if (Reporter.HasErrors(problems)) return 65;
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
catch (ThrownError thrown)
{
    // An error the program threw and never caught. Reported like any other failure —
    // a .NET stack trace reaching a student is exactly what §3.6 exists to prevent.
    Reporter.RuntimeFailure(
        new RuntimeError(
            thrown.Value.Message,

            // An assertion is thrown like anything else, so a catch and a test runner both
            // see it — but telling someone to wrap a failed assertion in a try would be
            // advice to hide the thing it was written to reveal.
            thrown.FromAssertion
                ? "An assertion states what the program guarantees. One that does not hold "
                  + "means the program is wrong, not that it needs catching."
                : "Nothing caught this. Wrap the risky part:  try { ... } catch e { ... }")
        { Line = thrown.Line },
        entryName, project);
    return 70;
}
catch (RuntimeError error)
{
    // Runtime diagnostics use the same voice as compile-time ones (§3.6): the subject
    // is the program, never the programmer, and no "fatal" or "invalid".
    Reporter.RuntimeFailure(error, entryName, project);
    return 70;
}
catch (Exception unexpected)
{
    // Last resort. Every failure above is one Emerald raised deliberately; this catches
    // the ones it did not, which are compiler bugs rather than program bugs. §3.6 exists
    // to keep a .NET stack trace away from a student, and without this the guarantee held
    // only for the paths someone remembered — `random(1)` reached an IndexOutOfRange and
    // printed twenty frames of Emerald's own internals.
    //
    // The type name is kept because it is the one useful thing in a bug report, and the
    // message says plainly whose fault it is.
    Reporter.RuntimeFailure(
        new RuntimeError(
            "The compiler hit a problem it did not expect, "
            + $"and stopped: {unexpected.GetType().Name}.",
            "This is a bug in Emerald, not in your program. "
            + $"What it said was: {unexpected.Message}"),
        entryName, project);
    return 70;
}
