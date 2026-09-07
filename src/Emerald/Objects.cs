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
public sealed record EmSuper(EmInstance Instance, EmClass DeclaredIn) : ICallable
{
    /// <summary>
    /// <c>super(name)</c> in a constructor — runs the base's constructor on this same
    /// object, so the base fills its own fields and does its own work. One word with one
    /// meaning: <c>super.speak()</c> is the method above, <c>super(...)</c> the
    /// constructor above. The checker allows the call form only as a constructor's first
    /// statement (§3.2), so reaching it anywhere else is a program that did not check.
    /// </summary>
    public object? Call(Interpreter interpreter, List<object?> args)
    {
        if (DeclaredIn.Super?.ConstructorOwner is not { } above)
            throw new RuntimeError(
                $"Nothing above {DeclaredIn.Name} has a constructor to call.");

        interpreter.RunConstructor(above, Instance, args);
        return null;
    }

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

    /// <summary>A file with no type in it. Its members see each other by bare name (§3.3).</summary>
    public bool IsModule { get; init; }

    /// <summary>Abstract members nothing has provided. Non-empty means not instantiable.</summary>
    public IReadOnlyList<string> Unimplemented => unimplemented;

    /// <summary>Type-level state and behavior: one copy, shared by every instance.</summary>
    public Dictionary<string, object?> Statics { get; } = [];

    /// <summary>
    /// A module's top-level <c>var</c>s, waiting to be given their values.
    ///
    /// An ordinary class's <c>static var</c> is evaluated when the type is declared. A
    /// module's cannot be: §3.3 says a module file's top-level code runs on first member
    /// access, and a top-level <c>var</c> <em>is</em> top-level code. Evaluating it early
    /// made a file act merely by existing &mdash; a module whose initializer named another
    /// module ran that one before the entry file executed a statement.
    ///
    /// Held rather than run, and merged back into the initializer by line, so the file
    /// still executes in the order it is written.
    /// </summary>
    public List<Stmt.VarDecl> DeferredFields { get; } = [];
    public Dictionary<string, List<Stmt.FuncDecl>> StaticMethods { get; } = [];

    /// <summary>Fields declared with a <c>get</c> body — computed rather than stored.</summary>
    public Dictionary<string, Stmt.VarDecl> Properties { get; } = [];

    /// <summary>
    /// What the traits provided, kept even where the class replaced it. The class's own
    /// methods are merged over these, so without a copy the replaced default is gone and
    /// <c>super.swim()</c> would have nothing to reach.
    /// </summary>
    public Dictionary<string, List<Stmt.FuncDecl>> FromTraits { get; } = [];

    /// <summary>
    /// The traits mixed into this class. FromTraits records what they <em>provided</em>,
    /// which is not the same question — a trait that is all abstract contributes no
    /// methods and would leave no trace there, and `x is Drawable` still has to say yes.
    /// </summary>
    public HashSet<string> TraitNames { get; } = [];

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
    public List<Stmt>? Initializer { get; set; }

    public bool Initialized { get; set; }

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
    /// Every overload of a name (§3.2), this class's own and the ones above it. An own
    /// method replaces an inherited one taking the same things and leaves its siblings
    /// reachable — the checker has already agreed which is which, so this only has to
    /// arrive at the same set.
    /// </summary>
    public List<Stmt.FuncDecl> FindMethods(string wanted)
    {
        List<Stmt.FuncDecl> found = methods.TryGetValue(wanted, out var mine) ? [.. mine] : [];

        foreach (var candidate in super?.FindMethods(wanted) ?? [])
            if (!found.Any(f => SameParams(f, candidate))) found.Add(candidate);

        foreach (var candidate in FromTraits.GetValueOrDefault(wanted, []))
            if (!found.Any(f => SameParams(f, candidate))) found.Add(candidate);

        return found;
    }

    /// <summary>
    /// Whether two declarations take the same things, by what they were written to take.
    /// Comparing the annotations rather than resolved types is enough here: the checker
    /// refuses a program where that would answer differently, so this is confirming its
    /// decision rather than making one.
    /// </summary>
    private static bool SameParams(Stmt.FuncDecl a, Stmt.FuncDecl b)
    {
        if (a.Params.Count != b.Params.Count) return false;

        for (int i = 0; i < a.Params.Count; i++)
        {
            var (mine, theirs) = (a.Params[i].Type, b.Params[i].Type);
            if (mine is null != theirs is null) return false;
            if (mine is not null && theirs is not null
                && (mine.Name.Lexeme != theirs.Name.Lexeme
                    || mine.Nullable != theirs.Nullable)) return false;
        }

        return true;
    }

    /// <summary>Base fields first, so a subclass's initializers can rely on them.</summary>
    public IEnumerable<Stmt.VarDecl> AllFields() =>
        (super?.AllFields() ?? []).Concat(fields);

    /// <summary>A subclass with no constructor of its own inherits its base's.</summary>
    public Stmt.ConstructorDecl? Constructor => constructor ?? super?.Constructor;

    /// <summary>This class's own constructor, not one it inherits.</summary>
    public Stmt.ConstructorDecl? OwnConstructor => constructor;

    /// <summary>
    /// Which class in the chain actually declares the constructor that runs. Needed
    /// wherever <see cref="Constructor"/> is not enough on its own: running one means
    /// knowing what <em>its</em> base is, so the chain can continue upward.
    /// </summary>
    public EmClass? ConstructorOwner =>
        constructor is not null ? this : super?.ConstructorOwner;

    /// <summary>
    /// Whether this class is, or descends from, one of a given name. Used for the
    /// prelude types the compiler owns — a program cannot redefine those names, so
    /// matching on one is not the fragile thing it would be for a user class.
    /// </summary>
    public bool Descends(string ancestor) =>
        name == ancestor || (super?.Descends(ancestor) ?? false);

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
/// orientation and color, and every one of those is a plain name.
///
/// A record, so <c>==</c> compares the two fields and two references to Color.RED are
/// equal without anything being written to make them so.
/// </summary>
public sealed record EmEnumValue(string Type, string Name, int Ordinal)
{
    /// <summary>The enum this belongs to, so a method call on a value can find one.</summary>
    public EmClass? Owner { get; init; }

    /// <summary>The enum value's own text, or <c>Suit.HEARTS</c> where it declares none.
    /// Reached the same way an instance's is, through the CLR method.</summary>
    public override string ToString() =>
        Runner is not null && Owner?.FindMethod(Builtins.ToStringMethod) is { } method
            ? Runner.CallEnumMethod(method, this, Owner, []) as string ?? $"{Type}.{Name}"
            : $"{Type}.{Name}";

    /// <summary>What can run this value's declared methods. See EmInstance.ToString.</summary>
    public Interpreter? Runner { get; init; }
}

public sealed class EmInstance(EmClass cls, Interpreter? runner = null) : IComparable
{
    public EmClass Class => cls;
    public Dictionary<string, object?> Fields { get; } = [];

    /// <summary>
    /// Ordering, through the CLR interface every orderable .NET type already implements.
    ///
    /// <c>&lt;</c> and <c>sort</c> used to reach a type's <c>compare</c> by two different
    /// routes, and only one of them arrived: the operator asked the class for the method,
    /// while sorting went through a comparer that knew about numbers and strings and
    /// nothing else. So <c>Money(1) &lt; Money(2)</c> answered, and
    /// <c>[Money(3), Money(1)].sort()</c> died inside the host's sort with "this is a bug
    /// in Emerald". One rule reached by one route is the whole point of asking through the
    /// CLR's own method.
    /// </summary>
    public int CompareTo(object? other)
    {
        if (runner is null)
            throw new RuntimeError($"{cls.Name} cannot be ordered here.");

        return runner.CompareInstances(this, other);
    }

    /// <summary>
    /// The object's own text, through the CLR method every .NET value already answers.
    ///
    /// An emitted Emerald class overrides <c>ToString</c> for real and needs none of this;
    /// the indirection exists only because an interpreted instance is a bag of fields with
    /// no methods on it, so running its <c>to_string</c> takes something that can run
    /// Emerald code. That is the whole of what the interpreter has to make up for, and it
    /// is confined to this one override.
    ///
    /// A type that has not said how it reads keeps the plain form, which is what leaves
    /// <c>&lt;Money&gt;</c> in place rather than inventing something.
    /// </summary>
    public override string ToString() =>
        runner is not null && cls.FindMethod(Builtins.ToStringMethod) is { } method
            ? runner.CallMethod(method, this, cls.Closure, []) as string ?? $"<{cls.Name}>"
            : $"<{cls.Name}>";
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
/// A built-in method with its receiver attached — <c>word.upper</c>. There is no
/// declaration to bind, only a name and the value to dispatch it on, which is all
/// <see cref="Builtins.InvokeMethod"/> ever needed. Without this a built-in was the one
/// kind of method that could not be named without calling it, and §3.1's rule would have
/// held everywhere except on the types a student uses most.
/// </summary>
public sealed class BuiltinMethod(object? receiver, string name) : ICallable
{
    public object? Call(Interpreter interpreter, List<object?> args) =>
        Builtins.InvokeMethod(interpreter, receiver, name, args);

    public override string ToString() => $"<method {name}>";
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
