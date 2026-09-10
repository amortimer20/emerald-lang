using Emerald;
using Emerald.Compiler;

// subclassspike <greeter.em> <Fixture.dll> <output.dll> -- checks the file the ordinary
// way, pulls out the one function it recognizes by name, and hands it to SubclassSpike
// along with which base type and methods it is standing in for. Exit 65 on a checker
// diagnostic, matching emitspike's own convention.

if (args.Length != 3)
{
    Console.Error.WriteLine("usage: subclassspike <greeter.em> <Fixture.dll> <output.dll>");
    return 64;
}

string path = args[0];
string fixturePath = args[1];
string output = args[2];

var project = new Project(path);
var program = project.Load();
var problems = project.Diagnostics;

if (problems.Count == 0)
{
    var checker = new Checker(Path.GetFileName(path), project.FileOf, project.LinesOf);
    checker.Check(program);
    problems = checker.Diagnostics;
}

if (problems.Count > 0)
{
    foreach (var p in problems) Console.Error.WriteLine($"{path}:{p.Line}  {p.Message}");
    return 65;
}

string entryName = Path.GetFileName(path);
var entryOnly = program.Where(s => project.FileOf.GetValueOrDefault(s) == entryName).ToList();

var greet = entryOnly.OfType<Stmt.FuncDecl>().SingleOrDefault(f => f.Name.Lexeme == "greet")
    ?? throw new InvalidOperationException("greeter.em must declare exactly one function named greet.");

SubclassSpike.Emit(
    greet, fixturePath, "Fixture.Greeter",
    overriddenMethod: "Greet", callThrough: "ShoutGreeting",
    derivedName: "EmeraldGreeter", outputPath: output);

return 0;
