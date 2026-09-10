using Emerald;
using Mono.Cecil;
using Mono.Cecil.Cil;

namespace Emerald.Compiler;

/// <summary>
/// Turns a checked program into a real .NET assembly, for exactly one shape of program:
/// a sequence of top-level <c>print("a string literal")</c> statements, and nothing else.
///
/// This is deliberately not the start of a general emitter. It is the smallest thing that
/// can compile and run, built to answer three questions before any real backend work
/// begins: does Mono.Cecil produce an assembly the current .NET runtime will load and
/// execute; does that assembly, once it calls into <see cref="Runtime.IO"/>, behave
/// identically to the interpreter running the same source; and does anything on this
/// machine — Smart App Control chief among the suspects named in docs/cil-mapping.html —
/// object to a freshly emitted assembly being executed, as opposed to one built by the
/// ordinary SDK. All three are things a real emitter would discover on its first day
/// regardless, and finding them here means finding them against ten lines of IL rather
/// than against however much a general emitter would have written by the time it first
/// runs.
///
/// Every unsupported shape is refused with a specific reason, not with a fallback --
/// there is nothing to fall back to. That is intentional: a spike that quietly did
/// something else on any program it could not handle would be answering none of the three
/// questions above.
/// </summary>
public static class Emitter
{
    /// <summary>
    /// Compiles <paramref name="program"/> to <paramref name="outputPath"/>, an assembly
    /// named after the file (extension included, since Cecil wants both handed the same
    /// way a build usually does).
    /// </summary>
    public static void Emit(List<Stmt> program, string outputPath)
    {
        List<string> lines = [];

        foreach (var stmt in program)
        {
            if (stmt is Stmt.ExprStmt
                {
                    Expression: Expr.Call
                    {
                        Callee: Expr.Variable { Name.Lexeme: "print" },
                        Args: [Expr.Literal { Value: string text }],
                        Trailing: null,
                    }
                })
            {
                lines.Add(text);
                continue;
            }

            throw new NotSupportedException(
                "This spike emits only print(\"a string literal\") statements, one per "
                + $"line, and met something else: {stmt.GetType().Name}. That is "
                + "everything it is for -- see Emerald.Compiler.Emitter's own comment.");
        }

        string assemblyName = Path.GetFileNameWithoutExtension(outputPath);
        var name = new AssemblyNameDefinition(assemblyName, new Version(1, 0, 0, 0));
        using var assembly = AssemblyDefinition.CreateAssembly(
            name, Path.GetFileName(outputPath), ModuleKind.Console);

        var module = assembly.MainModule;

        // Cecil resolves an imported CLR member by asking its AssemblyResolver to find the
        // assembly that declares it, by name, on disk -- so both the BCL and
        // Emerald.Runtime have to be reachable as search directories before anything can
        // be imported from either.
        var resolver = (BaseAssemblyResolver)module.AssemblyResolver;
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location));
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(Runtime.IO).Assembly.Location)!);

        var objectType = module.ImportReference(typeof(object));
        var printMethod = module.ImportReference(
            typeof(Runtime.IO).GetMethod(nameof(Runtime.IO.Print), [typeof(string)]));

        // One type, named for the file, holding one method. §3.3 already says a file
        // becomes a class and its top-level statements become that class's own code --
        // this is the same mapping, just hand-written instead of walked from a real
        // module builder.
        var program_ = new TypeDefinition(
            "", assemblyName,
            TypeAttributes.Public | TypeAttributes.Class | TypeAttributes.Sealed,
            objectType);
        module.Types.Add(program_);

        var main = new MethodDefinition(
            "Main",
            MethodAttributes.Public | MethodAttributes.Static,
            module.TypeSystem.Void);
        program_.Methods.Add(main);
        module.EntryPoint = main;

        var body = main.Body.GetILProcessor();
        foreach (var text in lines)
        {
            body.Emit(OpCodes.Ldstr, text);
            body.Emit(OpCodes.Call, printMethod);
        }
        body.Emit(OpCodes.Ret);

        assembly.Write(outputPath);
    }
}
