namespace Emerald;

/// <summary>
/// A class at runtime. Method and field lookup walk the base chain, which is all single
/// inheritance needs in a tree-walker — no vtables until there is a CIL backend.
/// </summary>
/// <summary>
/// <c>super</c> inside a method: the same instance, but looked up starting above the class
/// that declared the method being run. Carrying the declaring class rather than just the
/// instance is what stops <c>super.speak()</c> finding the override again and recursing —
/// which was not even a catchable error, but a stack overflow that killed the process.
/// </summary>
public sealed record EmSuper(EmInstance Instance, EmClass DeclaredIn)
{
    public override string ToString() => $"<super of {DeclaredIn.Name}>";
}

public sealed class EmClass(
    string name,
    TypeKind kind,
    EmClass? super,
    List<Stmt.VarDecl> fields,
    Dictionary<string, List<Stmt.FuncDecl>> methods,
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
    public Dictionary<string, List<Stmt.FuncDecl>> StaticMethods { get; } = [];

    /// <summary>Fields declared with a <c>get</c> body — computed rather than stored.</summary>
    public Dictionary<string, Stmt.VarDecl> Properties { get; } = [];

    /// <summary>
    /// What the traits provided, kept even where the class replaced it. The class's own
    /// methods are merged over these, so without a copy the replaced default is gone and
    /// <c>super.swim()</c> would have nothing to reach.
    /// </summary>
    public Dictionary<string, List<Stmt.FuncDecl>> FromTraits { get; } = [];

    /// <summary>Where <c>super</c> looks: the base chain first, then a trait's default.</summary>
    public List<Stmt.FuncDecl> Inherited(string wanted) =>
        super?.FindMethods(wanted) is { Count: > 0 } fromBase
            ? fromBase
            : FromTraits.GetValueOrDefault(wanted, []);

    /// <summary>
    /// Which class in the chain actually declares this method — where <c>super</c> starts
    /// counting from. Taking the receiver's own class would be wrong for a method inherited
    /// two levels down: <c>super</c> inside <c>Animal.speak</c> means <c>Animal</c>'s base,
    /// whichever subclass the instance happens to be.
    /// </summary>
    public EmClass? OwnerOfMethod(Stmt.FuncDecl method) =>
        methods.TryGetValue(method.Name.Lexeme, out var mine) && mine.Contains(method)
            ? this
            : super?.OwnerOfMethod(method);

    /// <summary>
    /// A module file's own top-level code, and whether it has run. §3.3 runs it once on
    /// first member access rather than at startup, which is what keeps Python's
    /// import-order problems from arising: nothing runs because a file merely exists.
    /// </summary>
    public List<Stmt>? Initialiser { get; set; }

    public bool Initialised { get; set; }

    public Stmt.VarDecl? FindProperty(string wanted) =>
        Properties.TryGetValue(wanted, out var p) ? p : super?.FindProperty(wanted);

    public Stmt.FuncDecl? FindStaticMethod(string wanted) =>
        FindStaticMethods(wanted).FirstOrDefault();

    public List<Stmt.FuncDecl> FindStaticMethods(string wanted) =>
        StaticMethods.TryGetValue(wanted, out var mine) ? mine
            : super?.FindStaticMethods(wanted) ?? [];

    public EmClass? OwnerOfStatic(string wanted) =>
        Statics.ContainsKey(wanted) ? this : super?.OwnerOfStatic(wanted);

    public IReadOnlyDictionary<string, List<Stmt.FuncDecl>> Methods => methods;

    /// <summary>The first of this name — enough where the name is fixed, as it is for the
    /// operator lowering and for asking whether a trait requirement is met.</summary>
    public Stmt.FuncDecl? FindMethod(string wanted) => FindMethods(wanted).FirstOrDefault();

    /// <summary>
    /// Every overload of a name (§3.2). Own methods shadow the base's rather than adding
    /// to them, which is what overriding already meant.
    /// </summary>
    public List<Stmt.FuncDecl> FindMethods(string wanted)
    {
        if (methods.TryGetValue(wanted, out var mine)) return mine;
        return super?.FindMethods(wanted) ?? [];
    }

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

/// <summary>
/// One value of an enum. Carries its type and its name, which is all a closed set of
/// names needs — no payload, because §6 harvested the demand as alignment, dock,
/// orientation and colour, and every one of those is a plain name.
///
/// A record, so <c>==</c> compares the two fields and two references to Colour.RED are
/// equal without anything being written to make them so.
/// </summary>
public sealed record EmEnumValue(string Type, string Name, int Ordinal)
{
    public override string ToString() => $"{Type}.{Name}";
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

/// <summary>
/// Several versions of one method, receiver attached. <c>g.hi</c> names them all: the
/// checker has already picked which one the expression's type refers to, and the runtime
/// has no types to pick with, so it keeps the set and chooses on the arguments the call
/// finally supplies. Both arrive at the same version, because the checker only let the
/// expression through against a shape exactly one of these answers.
/// </summary>
public sealed class BoundOverloads(
    List<Stmt.FuncDecl> alternatives, EmInstance receiver, Env closure) : ICallable
{
    public object? Call(Interpreter interpreter, List<object?> args) =>
        interpreter.CallOverload(alternatives, receiver, closure, args);

    public override string ToString() =>
        $"<method {alternatives[0].Name.Lexeme}>";
}

/// <summary>
/// A static method as a value. There is no receiver to attach, only the class the body
/// calls <c>Self</c>, so this is the type-level counterpart to <see cref="BoundMethod"/>.
/// </summary>
public sealed class StaticMethod(Stmt.FuncDecl declaration, EmClass owner) : ICallable
{
    public string Name => declaration.Name.Lexeme;

    public object? Call(Interpreter interpreter, List<object?> args) =>
        interpreter.CallStatic(declaration, owner, args);

    public override string ToString() => $"<method {owner.Name}.{declaration.Name.Lexeme}>";
}
