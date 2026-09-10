using Emerald;
using Mono.Cecil;
using Mono.Cecil.Cil;

namespace Emerald.Compiler;

/// <summary>
/// Section 5.2's first milestone: an Emerald class subclassing a C# class, with C# calling
/// back in. A second spike beside <see cref="Emitter"/>, and narrow the same way: one
/// exact shape, refused loudly outside it, and not the start of general interop.
///
/// Emerald has no syntax yet for extending a foreign type; teaching the checker to
/// resolve a base class it did not declare is real interop work, deliberately sequenced
/// after the backend rather than before it. So this does not go through <c>extends</c> at
/// all. It takes one ordinary, already-supported Emerald function -- checked by the real
/// pipeline, naming no foreign type anywhere in its own source -- and the driver decides
/// which CLR method on which CLR base class it becomes the override body for. The
/// question this answers is narrower than "can Emerald subclass C#": it is "once a
/// checked Emerald body exists, can Cecil graft it onto a real override slot on a real
/// base class, so that ordinary C# code calling the ordinary method the base class
/// already has ends up running Emerald's answer instead." That is the actual content of
/// "C# calling back in": the call that matters is not Emerald's, it is the base class's
/// own, unmodified, calling a virtual method it never implements itself.
///
/// The recognized shape: a zero-parameter function returning String, whose body is
/// exactly one <c>return "a string literal"</c>. Reuses <see cref="Emitter"/>'s own
/// refusal style -- anything else throws, by name, with no fallback.
/// </summary>
public static class SubclassSpike
{
    /// <summary>
    /// Emits a type named <paramref name="derivedName"/>, extending
    /// <paramref name="baseTypeName"/> from the assembly at <paramref name="basePath"/>,
    /// overriding <paramref name="overriddenMethod"/> with <paramref name="overrideBody"/>.
    /// The written assembly's entry point constructs one instance and passes the result
    /// of calling <paramref name="callThrough"/> -- an ordinary, non-overridden method the
    /// base class already has -- to <see cref="Runtime.IO.Print"/>.
    /// </summary>
    public static void Emit(
        Stmt.FuncDecl overrideBody, string basePath, string baseTypeName,
        string overriddenMethod, string callThrough, string derivedName, string outputPath)
    {
        string text = OnlyReturnedString(overrideBody);

        string assemblyName = Path.GetFileNameWithoutExtension(outputPath);
        var name = new AssemblyNameDefinition(assemblyName, new Version(1, 0, 0, 0));
        using var assembly = AssemblyDefinition.CreateAssembly(
            name, Path.GetFileName(outputPath), ModuleKind.Console);
        var module = assembly.MainModule;

        var resolver = (BaseAssemblyResolver)module.AssemblyResolver;
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location));
        resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(Runtime.IO).Assembly.Location)!);
        resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(basePath)));

        // The base type is named rather than reached through C#'s own typeof(), because
        // nothing in this project should carry a permanent reference to a throwaway test
        // fixture -- the same reason the compiler resolves Emerald.Runtime.IO through
        // reflection on an assembly it does control, rather than the other way round.
        var baseAssembly = module.AssemblyResolver.Resolve(
            AssemblyNameReference.Parse(Path.GetFileNameWithoutExtension(basePath)));
        var baseType = baseAssembly.MainModule.GetType(baseTypeName)
            ?? throw new NotSupportedException($"No type named {baseTypeName} in {basePath}.");
        var baseTypeRef = module.ImportReference(baseType);

        var baseCtor = module.ImportReference(
            baseType.Methods.Single(m => m.IsConstructor && m.Parameters.Count == 0));
        var abstractMethod = baseType.Methods.SingleOrDefault(m => m.Name == overriddenMethod)
            ?? throw new NotSupportedException(
                $"{baseTypeName} has no method named {overriddenMethod}.");
        var callThroughMethod = module.ImportReference(
            baseType.Methods.SingleOrDefault(m => m.Name == callThrough)
                ?? throw new NotSupportedException(
                    $"{baseTypeName} has no method named {callThrough}."));

        var derived = new TypeDefinition(
            "", derivedName,
            TypeAttributes.Public | TypeAttributes.Class | TypeAttributes.Sealed,
            baseTypeRef);
        module.Types.Add(derived);

        // A constructor doing nothing but the base's own -- Emerald has written no
        // constructor here because this spike bypasses class declarations entirely.
        var ctor = new MethodDefinition(
            ".ctor",
            MethodAttributes.Public | MethodAttributes.HideBySig
                | MethodAttributes.SpecialName | MethodAttributes.RTSpecialName,
            module.TypeSystem.Void);
        var ctorIl = ctor.Body.GetILProcessor();
        ctorIl.Emit(OpCodes.Ldarg_0);
        ctorIl.Emit(OpCodes.Call, baseCtor);
        ctorIl.Emit(OpCodes.Ret);
        derived.Methods.Add(ctor);

        // Public, virtual, no new slot: an override by signature match is exactly what
        // the C# compiler emits for the override keyword, and it is what makes the
        // vtable slot ShoutGreeting already calls through resolve to this rather than to
        // nothing. Getting this wrong -- NewSlot instead of reusing the base's slot -- is
        // the one thing in this file most likely to compile clean and dispatch wrong.
        var overrideMethod = new MethodDefinition(
            overriddenMethod,
            MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.HideBySig,
            module.ImportReference(typeof(string)));
        var body = overrideMethod.Body.GetILProcessor();
        body.Emit(OpCodes.Ldstr, text);
        body.Emit(OpCodes.Ret);
        derived.Methods.Add(overrideMethod);

        // Main: construct the derived instance, call the base's own unmodified method,
        // not the override, and print what comes back. If the vtable wiring above is
        // wrong, this is where it shows: callThrough runs C# code Emerald never touched,
        // and that code's only way to answer is to call back through the slot this
        // override claimed.
        var printMethod = module.ImportReference(
            typeof(Runtime.IO).GetMethod(nameof(Runtime.IO.Print), [typeof(string)]));

        var main = new MethodDefinition(
            "Main",
            MethodAttributes.Public | MethodAttributes.Static,
            module.TypeSystem.Void);
        module.Types.Add(new TypeDefinition(
            "", "EntryPoint",
            TypeAttributes.Public | TypeAttributes.Class | TypeAttributes.Sealed,
            module.ImportReference(typeof(object)))
        { Methods = { main } });
        module.EntryPoint = main;

        var mainIl = main.Body.GetILProcessor();
        mainIl.Emit(OpCodes.Newobj, ctor);
        mainIl.Emit(OpCodes.Call, callThroughMethod);
        mainIl.Emit(OpCodes.Call, printMethod);
        mainIl.Emit(OpCodes.Ret);

        assembly.Write(outputPath);
    }

    private static string OnlyReturnedString(Stmt.FuncDecl fn)
    {
        if (fn.Body is [Stmt.Return { Value: Expr.Literal { Value: string text } }])
            return text;

        throw new NotSupportedException(
            $"This spike only takes a body shaped like return \"text\", and {fn.Name.Lexeme} "
            + "is something else. That is everything it is for -- see SubclassSpike's own "
            + "comment.");
    }
}
