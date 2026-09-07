using Emerald;
using Emerald.Compiler;

// emitspike <file.em> <output.dll> -- checks the file the ordinary way, then hands the
// checked statements to the spike emitter. Exit 65 on a diagnostic, matching `emerald
// run`'s own convention, so a failure here is not mistaken for the emitter's.

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: emitspike <file.em> <output.dll>");
    return 64;
}

string path = args[0];
string output = args[1];

var project = new Project(path);
var program = project.Load();
var problems = project.Diagnostics;

// Project.Load's list is the whole program: the prelude's operator traits and Error
// class come first, then every other file, then the entry file's own statements last.
// The spike only ever emits the entry file's own code, so it is the only slice handed
// to the emitter -- everything else in `program` exists for the checker, not for this.
string entryName = Path.GetFileName(path);
var entryOnly = program.Where(s => project.FileOf.GetValueOrDefault(s) == entryName).ToList();

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

Emitter.Emit(entryOnly, output);
return 0;
