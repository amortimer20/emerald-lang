namespace Emerald;

/// <summary>
/// A class at runtime. Method and field lookup walk the base chain, which is all single
/// inheritance needs in a tree-walker — no vtables until there is a CIL backend.
/// </summary>
public sealed class EmClass(
    string name,
    TypeKind kind,
    EmClass? super,
    List<Stmt.VarDecl> fields,
    Dictionary<string, Stmt.FuncDecl> methods,
    Stmt.ConstructorDecl? constructor,
    List<string> unimplemented,
    Env closure) : ICallable
{
    public string Name => name;
    public TypeKind Kind => kind;
    public EmClass? Super => super;
    public Env Closure => closure;

    /// <summary>Abstract members nothing has provided. Non-empty means not instantiable.</summary>
    public IReadOnlyList<string> Unimplemented => unimplemented;

    /// <summary>Type-level state and behaviour: one copy, shared by every instance.</summary>
    public Dictionary<string, object?> Statics { get; } = [];
    public Dictionary<string, Stmt.FuncDecl> StaticMethods { get; } = [];

    /// <summary>Fields declared with a <c>get</c> body — computed rather than stored.</summary>
    public Dictionary<string, Stmt.VarDecl> Properties { get; } = [];

    public Stmt.VarDecl? FindProperty(string wanted) =>
        Properties.TryGetValue(wanted, out var p) ? p : super?.FindProperty(wanted);

    public Stmt.FuncDecl? FindStaticMethod(string wanted) =>
        StaticMethods.TryGetValue(wanted, out var m) ? m : super?.FindStaticMethod(wanted);

    public EmClass? OwnerOfStatic(string wanted) =>
        Statics.ContainsKey(wanted) ? this : super?.OwnerOfStatic(wanted);

    public IReadOnlyDictionary<string, Stmt.FuncDecl> Methods => methods;

    public Stmt.FuncDecl? FindMethod(string wanted) =>
        methods.TryGetValue(wanted, out var found) ? found : super?.FindMethod(wanted);

    /// <summary>Base fields first, so a subclass's initialisers can rely on them.</summary>
    public IEnumerable<Stmt.VarDecl> AllFields() =>
        (super?.AllFields() ?? []).Concat(fields);

    /// <summary>A subclass with no constructor of its own inherits its base's.</summary>
    public Stmt.ConstructorDecl? Constructor => constructor ?? super?.Constructor;

    public bool IsSubclassOf(EmClass other) =>
        this == other || (super?.IsSubclassOf(other) ?? false);

    // `Dog("Rex")` — construction is an ordinary call, with no `new` (§3.2).
    public object? Call(Interpreter interpreter, List<object?> args) =>
        interpreter.Instantiate(this, args);

    public override string ToString() => $"<class {name}>";
}

public sealed class EmInstance(EmClass cls)
{
    public EmClass Class => cls;
    public Dictionary<string, object?> Fields { get; } = [];

    public override string ToString() => $"<{cls.Name}>";
}

/// <summary>
/// A method with its receiver already attached. Produced by <c>dog.speak</c>, so the
/// same value works whether it is called immediately or passed around.
/// </summary>
public sealed class BoundMethod(Stmt.FuncDecl declaration, EmInstance receiver, Env closure)
    : ICallable
{
    public string Name => declaration.Name.Lexeme;

    public object? Call(Interpreter interpreter, List<object?> args) =>
        interpreter.CallMethod(declaration, receiver, closure, args);

    public override string ToString() => $"<method {declaration.Name.Lexeme}>";
}
