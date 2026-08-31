using System.Text;

namespace Emerald;

/// <summary>
/// Loads every <c>.em</c> file under the entry file's directory and stitches them into
/// one program (§3.3): no import statements are needed within a project.
///
/// v0 is flat — every type is visible by its simple name regardless of directory.
/// Directory-as-namespace (<c>Shapes.Dog</c>) is designed but not implemented, so a
/// project with two same-named types in different folders will collide.
/// </summary>
public sealed class Project(string entryPath)
{
    public string Root { get; } =
        Path.GetDirectoryName(Path.GetFullPath(entryPath)) ?? ".";

    private readonly Dictionary<string, string[]> _sources = [];

    public List<Diagnostic> Diagnostics { get; } = [];

    /// <summary>
    /// Which file each top-level statement came from. Without this the checker has one
    /// filename for the whole program and reports every error against the entry file.
    /// </summary>
    public Dictionary<Stmt, string> FileOf { get; } = new(ReferenceEqualityComparer.Instance);

    /// <summary>Source lines by file name, so a diagnostic can quote the right file.</summary>
    public string[] LinesOf(string fileName) =>
        _sources.TryGetValue(fileName, out var lines) ? lines : [];

    public List<Stmt> Load()
    {
        string entry = Path.GetFullPath(entryPath);

        // Declarations from other files come first, so the entry file can use anything the
        // project defines without regard to load order.
        List<Stmt> program = [];
        List<Stmt> entryStatements = [];

        foreach (string path in Directory
                     .EnumerateFiles(Root, "*.em", SearchOption.AllDirectories)
                     .OrderBy(p => p, StringComparer.Ordinal))
        {
            string fileName = Path.GetFileName(path);
            string source = File.ReadAllText(path);
            _sources[fileName] = source.Replace("\r\n", "\n").Split('\n');

            var scanner = new Scanner(source, fileName);
            var parser = new Parser(scanner.ScanTokens(), fileName);
            var statements = parser.ParseProgram();

            Diagnostics.AddRange(scanner.Diagnostics);
            Diagnostics.AddRange(parser.Diagnostics);

            List<Stmt> contributed = Path.GetFullPath(path) == entry
                ? statements
                : [.. Contribute(statements, fileName)];

            foreach (var stmt in contributed) FileOf[stmt] = fileName;

            if (Path.GetFullPath(path) == entry) entryStatements = contributed;
            else program.AddRange(contributed);
        }

        program.AddRange(entryStatements);
        return program;
    }

    /// <summary>
    /// A file that declares a type contributes it directly. A file that declares none is a
    /// module: it has no instances, so its members become a type named after the file, and
    /// they are reached as <c>MathUtils.clamp(...)</c> (§3.3).
    /// </summary>
    private static IEnumerable<Stmt> Contribute(List<Stmt> statements, string fileName)
    {
        if (statements.Any(s => s is Stmt.ClassDecl)) return statements;

        var name = new Token(TokenType.Identifier, ModuleName(fileName), null, 1);

        List<Stmt> members = [.. statements.Select(s => s switch
        {
            Stmt.FuncDecl f => f with { IsStatic = true },
            Stmt.VarDecl v => v with { IsStatic = true },
            _ => s,
        })];

        return [new Stmt.ClassDecl(TypeKind.Class, name, null, [], members)];
    }

    /// <summary>math_utils.em -> MathUtils</summary>
    private static string ModuleName(string fileName)
    {
        var result = new StringBuilder();
        bool capitalise = true;

        foreach (char c in Path.GetFileNameWithoutExtension(fileName))
        {
            if (c == '_') { capitalise = true; continue; }
            result.Append(capitalise ? char.ToUpperInvariant(c) : c);
            capitalise = false;
        }

        return result.Length == 0 ? "Module" : result.ToString();
    }
}
