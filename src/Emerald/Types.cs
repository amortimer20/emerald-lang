namespace Emerald;

/// <summary>
/// A type, as the checker sees it. Deliberately small: v0 has no classes or generics,
/// so this covers the primitives, nullability, and functions.
/// </summary>
public abstract record EmType
{
    public sealed record Prim(string Name) : EmType;

    /// <summary>T? — either a T or nothing (§3.2).</summary>
    public sealed record Maybe(EmType Inner) : EmType;

    /// <summary>
    /// <paramref name="Required"/> is how many arguments a caller must supply; anything
    /// beyond it has a default. Left at its maximum by every construction site that has
    /// no defaults to describe, so "all of them" needs no ceremony.
    /// </summary>
    public sealed record Func(List<EmType> Params, EmType Return, int Required = int.MaxValue) : EmType
    {
        public int LeastArgs => Math.Min(Required, Params.Count);
    }

    /// <summary>
    /// Array&lt;T&gt; — the one generic type in v0. Users cannot declare generics; the
    /// compiler owns the parameterised containers. That is §5.3's split, and exactly what
    /// Go did with slices and maps for a decade.
    /// </summary>
    public sealed record Arr(EmType Element) : EmType;

    /// <summary>An instance of a user-declared class.</summary>
    public sealed record Obj(ClassInfo Info) : EmType;

    /// <summary>
    /// An unannotated position — currently only lambda parameters, whose types would
    /// have to be inferred from the method being called. Compatible with everything, so
    /// the checker stays quiet rather than guessing. The honest v0 gap.
    /// </summary>
    public sealed record Unknown : EmType;

    public static readonly EmType Int = new Prim("Int");
    public static readonly EmType Float = new Prim("Float");
    public static readonly EmType String = new Prim("String");
    public static readonly EmType Bool = new Prim("Bool");
    public static readonly EmType Nothing = new Prim("Nothing");
    public static readonly EmType Range = new Prim("Range");
    public static readonly EmType Any = new Unknown();

    public static EmType Nullable(EmType inner) =>
        inner is Maybe ? inner : new Maybe(inner);

    /// <summary>The non-null form of a type. Narrowing produces this.</summary>
    public EmType Stripped => this is Maybe m ? m.Inner : this;

    public bool IsMaybe => this is Maybe;

    public string Show() => this switch
    {
        Prim p => p.Name,
        Maybe m => m.Inner.Show() + "?",
        Arr a => $"Array<{a.Element.Show()}>",
        Obj o => o.Info.Name,
        Func => "Function",
        _ => "?"
    };

    /// <summary>The name used to look up methods — <c>Array&lt;Int&gt;</c> resolves as Array.</summary>
    public string Head => this switch
    {
        Prim p => p.Name,
        Arr => "Array",
        Obj o => o.Info.Name,
        Func => "Function",
        Maybe m => m.Inner.Head,
        _ => "?"
    };

    /// <summary>
    /// Can a value of <paramref name="from"/> be used where <c>this</c> is wanted?
    /// The asymmetry that matters: T fits into T?, but T? does not fit into T. That is
    /// the whole of what non-nullable-by-default buys.
    /// </summary>
    public bool Accepts(EmType from)
    {
        if (this is Unknown || from is Unknown) return true;
        if (Equals(from)) return true;

        // nothing is a legal value for any nullable type.
        if (this is Maybe && from is Prim { Name: "Nothing" }) return true;

        // T widens into T?.
        if (this is Maybe self) return self.Inner.Accepts(from.Stripped) && !from.IsMaybe;

        // Int widens into Float, but not the reverse — no silent truncation.
        if (Equals(Float) && from.Equals(Int)) return true;

        if (this is Arr x && from is Arr y) return x.Element.Accepts(y.Element);

        // A subclass is usable wherever its base is wanted.
        if (this is Obj want && from is Obj got) return got.Info.IsSubclassOf(want.Info);

        if (this is Func a && from is Func b)
            return a.Params.Count == b.Params.Count;

        return false;
    }
}

/// <summary>
/// Return types for the built-in methods. v0 checks what a method <em>gives back</em>
/// but not what it takes — enough for inference and narrowing to work, and honest about
/// being partial. A full signature table arrives with the real standard library.
/// </summary>
public static class Signatures
{
    private static readonly Dictionary<(string, string), EmType> Returns = new()
    {
        // Int
        [("Int", "times")] = EmType.Nothing,   [("Int", "upto")] = EmType.Nothing,
        [("Int", "downto")] = EmType.Nothing,  [("Int", "even?")] = EmType.Bool,
        [("Int", "odd?")] = EmType.Bool,       [("Int", "zero?")] = EmType.Bool,
        [("Int", "positive?")] = EmType.Bool,  [("Int", "negative?")] = EmType.Bool,
        [("Int", "between?")] = EmType.Bool,   [("Int", "clamp")] = EmType.Int,
        [("Int", "abs")] = EmType.Int,         [("Int", "to_string")] = EmType.String,
        [("Int", "to_float")] = EmType.Float,

        // Float
        [("Float", "round")] = EmType.Int,     [("Float", "floor")] = EmType.Int,
        [("Float", "ceil")] = EmType.Int,      [("Float", "abs")] = EmType.Float,
        [("Float", "zero?")] = EmType.Bool,    [("Float", "positive?")] = EmType.Bool,
        [("Float", "negative?")] = EmType.Bool,
        [("Float", "to_string")] = EmType.String, [("Float", "to_int")] = EmType.Int,

        // String
        [("String", "length")] = EmType.Int,   [("String", "empty?")] = EmType.Bool,
        [("String", "upper")] = EmType.String, [("String", "lower")] = EmType.String,
        [("String", "reverse")] = EmType.String, [("String", "trim")] = EmType.String,
        [("String", "contains?")] = EmType.Bool,
        [("String", "starts_with?")] = EmType.Bool,
        [("String", "ends_with?")] = EmType.Bool,
        [("String", "to_int")] = EmType.Int,
        [("String", "to_int_or")] = EmType.Int,
        [("String", "to_string")] = EmType.String,

        // The one that makes narrowing worth having.
        [("String", "to_int_maybe")] = EmType.Nullable(EmType.Int),
        [("String", "to_float")] = EmType.Float,
        [("String", "to_float_or")] = EmType.Float,
        [("String", "to_float_maybe")] = EmType.Nullable(EmType.Float),

        // §3.2 promised these when it ruled out integer indexing on strings.
        [("String", "chars")] = new EmType.Arr(EmType.String),
        [("String", "split")] = new EmType.Arr(EmType.String),
        [("String", "replace")] = EmType.String,

        // Math — free functions that replace no syntax, so §3.7 sends them to a module.
        [("Math", "pi")] = EmType.Float,      [("Math", "e")] = EmType.Float,
        [("Math", "sqrt")] = EmType.Float,    [("Math", "pow")] = EmType.Float,
        [("Math", "min")] = EmType.Any,       [("Math", "max")] = EmType.Any,

        // Range
        [("Range", "each")] = EmType.Nothing,  [("Range", "count")] = EmType.Int,
        [("Range", "contains?")] = EmType.Bool,
        [("Range", "first")] = EmType.Int,     [("Range", "last")] = EmType.Int,

        // Bool
        [("Bool", "to_string")] = EmType.String,

        // Error
        [("Error", "message")] = EmType.String,
        [("Error", "to_string")] = EmType.String,
    };

    public static bool TryLookup(EmType receiver, string method, out EmType result)
    {
        result = EmType.Any;
        if (receiver is EmType.Unknown) return true;
        return Returns.TryGetValue((receiver.Head, method), out result!);
    }

    /// <summary>Method names on this type, for "did you mean" suggestions (§3.6).</summary>
    public static IEnumerable<string> MethodsOn(EmType receiver) =>
        receiver is EmType.Arr
            ? ArrayMethods
            : Returns.Keys.Where(k => k.Item1 == receiver.Head).Select(k => k.Item2);

    /// <summary>
    /// The core twenty (§3.7). Return types depend on the element type, so unlike the
    /// table above these are resolved in the checker rather than looked up.
    /// </summary>
    public static readonly string[] ArrayMethods =
    [
        "each", "map", "filter", "reject", "find", "index_of", "contains?",
        "any?", "all?", "empty?", "reduce", "count", "sum", "min", "max",
        "sort", "sort_by", "reverse", "first", "last", "join",
        "add", "remove", "remove_at", "clear",
    ];

    /// <summary>Methods whose last argument is a block taking one element.</summary>
    public static readonly HashSet<string> TakesElementBlock =
        ["each", "map", "filter", "reject", "find", "any?", "all?", "sort_by"];

    /// <summary>
    /// Plausible names for things that are called something else. Emerald deliberately
    /// has no aliases — two names for one method is the absence of a blessed default
    /// (§2.4), and it makes the API worse to explore rather than better. But the problem
    /// aliases solve is real: you can forget whether it is <c>chars</c> or
    /// <c>characters</c>. This solves it in the diagnostic instead, so there is still one
    /// name in the API and one in autocomplete — and a wrong guess teaches the right name
    /// rather than quietly working and leaving two dialects in circulation.
    ///
    /// Edit distance alone cannot do this: <c>to_integer</c> is four edits from
    /// <c>to_int</c>, well past the threshold, and <c>quit</c> shares almost nothing with
    /// <c>exit</c>.
    /// </summary>
    public static readonly Dictionary<string, string> KnownByAnotherName = new()
    {
        ["characters"] = "chars",
        ["to_integer"] = "to_int",
        ["to_i"] = "to_int",
        ["to_s"] = "to_string",
        ["to_str"] = "to_string",
        ["to_f"] = "to_float",
        ["size"] = "count",
        ["len"] = "count",
        ["length"] = "count",
        ["push"] = "add",
        ["append"] = "add",
        ["collect"] = "map",
        ["select"] = "filter",
        ["detect"] = "find",
        ["inject"] = "reduce",
        ["fold"] = "reduce",
        ["includes?"] = "contains?",
        ["include?"] = "contains?",
        ["has?"] = "contains?",
        ["upcase"] = "upper",
        ["downcase"] = "lower",
        ["uppercase"] = "upper",
        ["lowercase"] = "lower",
        ["strip"] = "trim",
        ["quit"] = "exit",
        ["halt"] = "exit",
        ["puts"] = "print",
        ["println"] = "print",
        ["input"] = "read_line",
        ["gets"] = "read_line",
        ["sqr"] = "sqrt",
        ["power"] = "pow",
    };
}

/// <summary>
/// What the checker knows about a user-declared class. Field and method lookup walk the
/// base chain, mirroring how <see cref="EmClass"/> resolves them at runtime — the two
/// have to agree, or the checker will accept programs the interpreter rejects.
/// </summary>
public sealed class ClassInfo(string name)
{
    public string Name => name;
    public TypeKind Kind { get; set; }
    public ClassInfo? Base { get; set; }
    public List<ClassInfo> Traits { get; } = [];

    /// <summary>Members declared abstract here — required, not provided.</summary>
    public HashSet<string> AbstractNames { get; } = [];
    public Dictionary<string, EmType> Fields { get; } = [];
    public Dictionary<string, EmType> StaticFields { get; } = [];
    public Dictionary<string, EmType.Func> StaticMethods { get; } = [];

    /// <summary>Fields declared with a get body. Indistinguishable to callers.</summary>
    public HashSet<string> PropertyNames { get; } = [];

    /// <summary>
    /// Fields given a value where they are declared. Those run before the constructor, so
    /// the constructor owes them nothing.
    /// </summary>
    public HashSet<string> InitialisedFields { get; } = [];

    /// <summary>
    /// Fields that hold nothing unless a constructor puts something there — the whole
    /// inheritance chain, because only one constructor runs (the most derived), so it is
    /// responsible for the base's fields too.
    ///
    /// A nullable field is excluded: <c>nothing</c> is a legal value for it, which is
    /// exactly what declaring it <c>T?</c> means. An unannotated one is excluded because
    /// its type is Unknown, and Unknown is where the checker stays quiet by policy.
    /// </summary>
    public IEnumerable<(string Name, EmType Type)> FieldsNeedingAValue() =>
        (Base?.FieldsNeedingAValue() ?? [])
            .Concat(Fields
                .Where(f => !InitialisedFields.Contains(f.Key)
                            && !PropertyNames.Contains(f.Key)
                            && f.Value is not EmType.Unknown
                            && !f.Value.IsMaybe)
                .Select(f => (f.Key, f.Value)));
    public HashSet<string> ReadOnlyProperties { get; } = [];
    public Dictionary<string, EmType.Func> Methods { get; } = [];
    public List<EmType> ConstructorParams { get; set; } = [];

    /// <summary>How many of them a caller must supply — see <see cref="EmType.Func"/>.</summary>
    public int ConstructorRequired { get; set; } = int.MaxValue;

    public bool HasConstructor { get; set; }

    /// <summary>A class is usable as its base and as any trait it mixes in.</summary>
    public bool IsSubclassOf(ClassInfo other) =>
        this == other
        || (Base?.IsSubclassOf(other) ?? false)
        || Traits.Any(t => t.IsSubclassOf(other));

    public EmType? FindField(string wanted) =>
        Fields.TryGetValue(wanted, out var t) ? t : Base?.FindField(wanted);

    public EmType.Func? FindMethod(string wanted) =>
        Methods.TryGetValue(wanted, out var m) ? m
            : Base?.FindMethod(wanted)
              ?? Traits.Select(t => t.FindMethod(wanted)).FirstOrDefault(f => f is not null);

    /// <summary>
    /// Resolved lazily rather than copied at declaration time, so a trait may be declared
    /// after the class that mixes it in — order in a file should not matter.
    /// </summary>
    public bool Provides(string wanted) =>
        (Methods.ContainsKey(wanted) && !AbstractNames.Contains(wanted))
        || (Base?.Provides(wanted) ?? false)
        || Traits.Any(t => t.Provides(wanted));

    public IEnumerable<string> Required() =>
        AbstractNames
            .Concat(Base?.Required() ?? [])
            .Concat(Traits.SelectMany(t => t.Required()));

    public IEnumerable<string> Missing() =>
        Required().Distinct().Where(n => !Provides(n));

    public EmType? FindStatic(string wanted) =>
        StaticFields.TryGetValue(wanted, out var f) ? f
            : StaticMethods.TryGetValue(wanted, out var m) ? m.Return
            : Base?.FindStatic(wanted);

    public IEnumerable<string> StaticNames() =>
        StaticFields.Keys.Concat(StaticMethods.Keys).Concat(Base?.StaticNames() ?? []);

    public IEnumerable<string> MemberNames() =>
        Fields.Keys
            .Concat(Methods.Keys)
            .Concat(Base?.MemberNames() ?? [])
            .Concat(Traits.SelectMany(t => t.MemberNames()));
}
