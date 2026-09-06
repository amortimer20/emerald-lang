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
    /// List&lt;T&gt; — the one generic type there is. Users cannot declare generics; the
    /// compiler owns the parameterised containers. That is §5.3's split, and exactly what
    /// Go did with slices and maps for a decade.
    /// </summary>
    public sealed record Lst(EmType Element) : EmType;

    /// <summary>
    /// Dictionary&lt;K, V&gt; — the second compiler-owned container (§3.7). Looking one up
    /// gives back <c>V?</c> rather than throwing, because a missing key is the ordinary
    /// case for a lookup, where a missing list position is a bug.
    /// </summary>
    public sealed record Dict(EmType Key, EmType Value) : EmType;

    /// <summary>
    /// Set&lt;T&gt; — the third core container (§3.7). Built from a list with
    /// <c>.to_set</c> rather than having a literal of its own: the braces Python uses are
    /// a block and a trailing lambda here, and the bracket is already a list's.
    /// </summary>
    public sealed record SetOf(EmType Element) : EmType;

    /// <summary>
    /// Two or more functions of one name (§3.2). A call picks the one whose parameters
    /// accept what it was handed; §3.2 makes overlap an error at the <em>declaration</em>,
    /// so at most one can ever match and there is no call-site resolution to teach.
    /// </summary>
    public sealed record Overloads(List<Func> Alternatives) : EmType;

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
        Lst a => $"List<{a.Element.Show()}>",
        Dict d => $"Dictionary<{d.Key.Show()}, {d.Value.Show()}>",
        SetOf t => $"Set<{t.Element.Show()}>",
        Obj o => o.Info.Name,

        // Written the way it is declared, so a mismatch reads as one: "expects func() but
        // this is func(Int)" says what to change, where two identical "Function"s did not.
        // The return is left off when there is none, matching a declaration with no `: T`.
        Func f => $"func({string.Join(", ", f.Params.Select(p => p.Show()))})"
                  + (f.Return.Equals(Nothing) || f.Return is Unknown ? "" : $": {f.Return.Show()}"),

        Overloads => "func",
        _ => "?"
    };

    /// <summary>The name used to look up methods — <c>List&lt;Int&gt;</c> resolves as List.</summary>
    public string Head => this switch
    {
        Prim p => p.Name,
        Lst => "List",
        Dict => "Dictionary",
        SetOf => "Set",
        Obj o => o.Info.Name,
        Func => "Function",
        Maybe m => m.Inner.Head,
        _ => "?"
    };

    /// <summary>
    /// Whether two parameter types could both accept one argument. §3.2 rejects an
    /// overload that overlaps an existing one, and this is what overlap means: not that
    /// the types are equal, but that no argument could tell them apart. <c>Int</c> and
    /// <c>Float</c> overlap because an Int widens; <c>Int</c> and <c>String</c> do not.
    /// </summary>
    public bool Overlaps(EmType other) => Accepts(other) || other.Accepts(this);

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

        if (this is Lst x && from is Lst y) return x.Element.Accepts(y.Element);

        if (this is Dict a2 && from is Dict b2)
            return a2.Key.Accepts(b2.Key) && a2.Value.Accepts(b2.Value);

        if (this is SetOf s1 && from is SetOf s2) return s1.Element.Accepts(s2.Element);

        // A subclass is usable wherever its base is wanted.
        if (this is Obj want && from is Obj got) return got.Info.IsSubclassOf(want.Info);

        // A function value is the one thing here with a whole shape written down, and this
        // compared only how many parameters it had — so func(String): String was accepted
        // where func(Int): Int was asked for, called with an Int, and its answer used as a
        // String. Parameters go the other way round from the return: whatever is handed
        // over must accept everything the receiver will pass it, and give back something
        // the receiver can use.
        if (this is Func wanted && from is Func given)
        {
            if (wanted.Params.Count != given.Params.Count) return false;

            for (int i = 0; i < wanted.Params.Count; i++)
                if (!given.Params[i].Accepts(wanted.Params[i])) return false;

            // A receiver that declares no return does not look at the answer, so anything
            // may come back — discarding a value is not a mistake.
            return wanted.Return.Equals(Nothing) || wanted.Return.Accepts(given.Return);
        }

        return false;
    }
}

/// <summary>
/// What the built-in methods take and give back.
///
/// This was a table of return types alone, which meant the checker knew what
/// <c>"hi".replace(...)</c> produced and nothing about what it wanted — so
/// <c>"hello".replace("l")</c>, missing an argument, passed. The language checked the
/// code you wrote and not the code it shipped, which is the inconsistency a student meets
/// first: their own mistakes are caught and the standard library's are not.
/// </summary>
public static class Signatures
{
    /// <summary>
    /// <paramref name="Takes"/> is the arguments written in the parentheses. A block is
    /// counted separately, since <c>5.times { }</c> passes one and it is not an argument
    /// in the sense the parentheses mean.
    /// </summary>
    public sealed record Signature(EmType Returns, EmType[] Takes, bool WantsBlock = false,
                                  int Required = -1)
    {
        public Signature(EmType returns) : this(returns, []) { }

        /// <summary>
        /// The fewest arguments a call may pass. Defaults to all of them — the standard
        /// library had no way to say otherwise, so <c>pad_right(20)</c> could not have an
        /// optional fill character while an ordinary function could (§3.2).
        /// </summary>
        public int Least => Required < 0 ? Takes.Length : Required;
    }

    private static readonly EmType Int = EmType.Int;
    private static readonly EmType Float = EmType.Float;
    private static readonly EmType Str = EmType.String;
    private static readonly EmType Bool = EmType.Bool;
    private static readonly EmType Void = EmType.Nothing;

    private static readonly Dictionary<(string, string), Signature> Table = new()
    {
        // Int
        [("Int", "times")] = new(Void, [], WantsBlock: true),
        [("Int", "upto")] = new(Void, [Int], WantsBlock: true),
        [("Int", "downto")] = new(Void, [Int], WantsBlock: true),
        [("Int", "even?")] = new(Bool),        [("Int", "odd?")] = new(Bool),
        [("Int", "zero?")] = new(Bool),        [("Int", "positive?")] = new(Bool),
        [("Int", "negative?")] = new(Bool),
        [("Int", "between?")] = new(Bool, [Int, Int]),
        [("Int", "clamp")] = new(Int, [Int, Int]),
        [("Int", "abs")] = new(Int),           [("Int", "to_string")] = new(Str),
        [("Int", "to_float")] = new(Float),

        // Curriculum, admitted as exceptions rather than through §3.7's gate.
        [("Int", "gcd")] = new(Int, [Int]),    [("Int", "lcm")] = new(Int, [Int]),
        [("Int", "digits")] = new(new EmType.Lst(Int)),

        // Float
        [("Float", "round")] = new(Int),       [("Float", "floor")] = new(Int),
        [("Float", "ceil")] = new(Int),        [("Float", "abs")] = new(Float),
        [("Float", "zero?")] = new(Bool),      [("Float", "positive?")] = new(Bool),
        [("Float", "negative?")] = new(Bool),
        [("Float", "to_string")] = new(Str),   [("Float", "to_int")] = new(Int),
        [("Float", "round_to")] = new(Float, [Int]),

        // Now that == follows IEEE, `x == x` no longer finds a NaN and this is the only
        // way to ask -- which is exactly why C# ships Double.IsNaN.
        [("Float", "nan?")] = new(Bool),       [("Float", "infinite?")] = new(Bool),

        // String
        [("String", "count")] = new(Int),      [("String", "empty?")] = new(Bool),
        [("String", "upper")] = new(Str),      [("String", "lower")] = new(Str),
        [("String", "reverse")] = new(Str),    [("String", "trim")] = new(Str),

        // Width. The fill is optional and a space when left out.
        [("String", "pad_left")] = new(Str, [Int, Str], Required: 1),
        [("String", "pad_right")] = new(Str, [Int, Str], Required: 1),
        [("String", "pad_center")] = new(Str, [Int, Str], Required: 1),
        [("String", "repeat")] = new(Str, [Int]),

        [("String", "letter?")] = new(Bool),   [("String", "digit?")] = new(Bool),
        [("String", "blank?")] = new(Bool),
        [("String", "contains?")] = new(Bool, [Str]),
        [("String", "starts_with?")] = new(Bool, [Str]),
        [("String", "ends_with?")] = new(Bool, [Str]),
        [("String", "to_int")] = new(Int),
        [("String", "to_int_or")] = new(Int, [Int]),
        [("String", "to_string")] = new(Str),

        // The one that makes narrowing worth having.
        [("String", "to_int_maybe")] = new(EmType.Nullable(EmType.Int)),
        [("String", "to_float")] = new(Float),
        [("String", "to_float_or")] = new(Float, [Float]),
        [("String", "to_float_maybe")] = new(EmType.Nullable(EmType.Float)),

        // §3.2 promised these when it ruled out integer indexing on strings.
        [("String", "chars")] = new(new EmType.Lst(EmType.String)),
        [("String", "split")] = new(new EmType.Lst(EmType.String), [Str]),
        [("String", "replace")] = new(Str, [Str, Str]),

        // slice is the sanctioned route to a substring, since §3.2 keeps strings out of
        // the index syntax. The count is optional and means "the rest".
        [("String", "slice")] = new(Str, [Int, Int], Required: 1),
        [("String", "index_of")] = new(Int, [Str]),
        [("String", "capitalize")] = new(Str),
        [("String", "trim_start")] = new(Str),
        [("String", "trim_end")] = new(Str),

        // Math — free functions that replace no syntax, so §3.7 sends them to a module.
        [("Math", "pi")] = new(Float),         [("Math", "e")] = new(Float),
        [("Math", "sqrt")] = new(Float, [Float]),
        [("Math", "pow")] = new(Float, [Float, Float]),

        // min and max keep Int in, Int out, so their result cannot be pinned here.
        [("Math", "min")] = new(EmType.Any, [EmType.Any, EmType.Any]),
        [("Math", "max")] = new(EmType.Any, [EmType.Any, EmType.Any]),

        // Kernel is deliberately absent. It resolves through the checker's own kernel
        // signatures — the same ones the bare names use — because a second table here
        // promptly disagreed with the first: it gave `random` one parameter where the
        // function takes two, so `Kernel.random(1, 6)` was refused and `random(1, 6)` was
        // not. One name, one signature, whichever way it is written.

        // Range
        [("Range", "each")] = new(Void, [], WantsBlock: true),
        [("Range", "count")] = new(Int),
        [("Range", "contains?")] = new(Bool, [Int]),
        [("Range", "first")] = new(Int),       [("Range", "last")] = new(Int),

        // Bool
        [("Bool", "to_string")] = new(Str),

        // Error
        [("Error", "message")] = new(Str),
        [("Error", "to_string")] = new(Str),
    };

    public static bool TryLookup(EmType receiver, string method, out EmType result)
    {
        result = EmType.Any;
        if (receiver is EmType.Unknown) return true;
        if (!Table.TryGetValue((receiver.Head, method), out var signature)) return false;

        result = signature.Returns;
        return true;
    }

    public static Signature? SignatureOf(EmType receiver, string method) =>
        Table.GetValueOrDefault((receiver.Head, method));

    /// <summary>
    /// Every built-in type that has a method of this name. Lets an unknown <em>global</em>
    /// name be answered with the method it probably meant — <c>round(x)</c> written by
    /// someone whose last language had it as a function, where here it is
    /// <c>x.round</c>. Without this the diagnostic says "declare it first", which sends
    /// them somewhere false (§3.6).
    /// </summary>
    public static IEnumerable<string> TypesWithMethod(string name) =>
        Table.Keys.Where(k => k.Item2 == name).Select(k => k.Item1).Distinct();

    /// <summary>Method names on this type, for "did you mean" suggestions (§3.6).</summary>
    public static IEnumerable<string> MethodsOn(EmType receiver) => receiver switch
    {
        EmType.Lst => ListMethods,
        EmType.Dict => DictMethods,
        EmType.SetOf => SetMethods,
        _ => Table.Keys.Where(k => k.Item1 == receiver.Head).Select(k => k.Item2),
    };

    /// <summary>
    /// The core twenty (§3.7). Return types depend on the element type, so unlike the
    /// table above these are resolved in the checker rather than looked up.
    /// </summary>
    /// <summary>
    /// What a dictionary can be asked. Deliberately not <c>contains?</c>: on a list that
    /// question has one meaning, and on a dictionary it has two — so the name says which.
    /// </summary>
    /// <summary>
    /// What a set can be asked. <c>contains?</c> is unambiguous here where it was not on a
    /// dictionary — a set holds one kind of thing, so there is only one question to ask.
    /// </summary>
    /// <summary>
    /// What every container answers to. Kept beside the three lists below rather than
    /// spelled into each, so a member added to the shared set cannot reach one container's
    /// suggestions and miss another's.
    /// </summary>
    public static readonly string[] Shared = Builtins.Shared;

    /// <summary>
    /// Answered by every value there is, so it belongs to no one type's list. §3.1 has no
    /// properties on built-ins, so it is a call like everything else.
    /// </summary>
    public const string TypeNameMethod = "type_name";

    public static readonly string[] SetMethods =
    [
        .. Shared,
        "contains?", "add", "remove", "clear",
        "union", "intersect", "difference", "subset_of?", "superset_of?",
    ];

    /// <summary>
    /// A dictionary walks in pairs, so the shared members that hand an element back have
    /// no shape to give and are left out. They still resolve, and say why.
    /// </summary>
    public static readonly string[] DictMethods =
    [
        .. Shared.Where(m => m is not ("find" or "min" or "max" or "to_list" or "sum")),
        "has_key?", "has_value?", "keys", "values", "get", "set", "remove", "clear",
    ];

    public static readonly string[] ListMethods =
    [
        .. Shared,
        "index_of", "contains?", "sort", "sort_by", "reverse", "first", "last", "join",
        "add", "insert_at", "remove", "remove_at", "clear", "to_set",
    ];

    /// <summary>A range walks whole numbers, and answers to the shared set like the rest.</summary>
    public static readonly string[] RangeMethods =
        [.. Shared, "contains?", "first", "last"];

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
        ["value"] = "must",
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
    /// <summary>
    /// Methods by name, each name holding every overload of it (§3.2). A list rather than
    /// one signature, because two methods may share a name when their parameters differ —
    /// and a subclass declaring a name replaces the base's set for that name entirely,
    /// which is what overriding already meant.
    /// </summary>
    public Dictionary<string, List<EmType.Func>> StaticMethods { get; } = [];

    /// <summary>Fields declared with a get body. Indistinguishable to callers.</summary>
    public HashSet<string> PropertyNames { get; } = [];

    /// <summary>
    /// Fields given a value where they are declared. Those run before the constructor, so
    /// the constructor owes them nothing.
    /// </summary>
    public HashSet<string> InitializedFields { get; } = [];

    /// <summary>
    /// Fields that hold nothing unless a constructor puts something there — the whole
    /// inheritance chain, because only one constructor runs (the most derived), so it is
    /// responsible for the base's fields too.
    ///
    /// A nullable field is excluded: <c>nothing</c> is a legal value for it, which is
    /// exactly what declaring it <c>T?</c> means. An unannotated one is excluded because
    /// its type is Unknown, and Unknown is where the checker stays quiet by policy.
    /// </summary>
    /// <summary>
    /// The fields this class must fill itself. Inherited ones are not among them: the
    /// base's constructor fills those, and it always runs — explicitly through
    /// <c>super(...)</c>, or implicitly when it needs nothing (§3.2).
    ///
    /// Before chaining existed this walked the base chain, and it had to, because nothing
    /// else was going to fill them. What that produced was a subclass repeating its
    /// base's assignments: it compiled, it silently skipped whatever the base's
    /// constructor did with those values, and it broke the day the base gained a field.
    /// </summary>
    public IEnumerable<(string Name, EmType Type)> FieldsNeedingAValue() =>
        Fields
            .Where(f => !InitializedFields.Contains(f.Key)
                        && !PropertyNames.Contains(f.Key)
                        && f.Value is not EmType.Unknown
                        && !f.Value.IsMaybe)
            .Select(f => (f.Key, f.Value));
    public HashSet<string> ReadOnlyProperties { get; } = [];
    public Dictionary<string, List<EmType.Func>> Methods { get; } = [];
    public List<EmType> ConstructorParams { get; set; } = [];

    /// <summary>How many of them a caller must supply — see <see cref="EmType.Func"/>.</summary>
    public int ConstructorRequired { get; set; } = int.MaxValue;

    public bool HasConstructor { get; set; }

    /// <summary>Carries @mirrors, so its member names came from a foreign API (§3.4).</summary>
    public bool Mirrors { get; set; }

    /// <summary>A class is usable as its base and as any trait it mixes in.</summary>
    public bool IsSubclassOf(ClassInfo other) =>
        this == other
        || (Base?.IsSubclassOf(other) ?? false)
        || Traits.Any(t => t.IsSubclassOf(other));

    public EmType? FindField(string wanted) =>
        Fields.TryGetValue(wanted, out var t) ? t : Base?.FindField(wanted);

    /// <summary>
    /// The first method of this name. Enough for everything that only asks whether one
    /// exists — trait requirements, and the operator lowering, where the name is fixed.
    /// </summary>
    public EmType.Func? FindMethod(string wanted) => FindMethods(wanted).FirstOrDefault();

    /// <summary>
    /// Every overload of a name, from wherever it is first declared. Own methods shadow
    /// the base's rather than adding to them: a subclass writing <c>speak</c> replaces
    /// what it inherited, which is what an override has always meant here.
    /// </summary>
    public List<EmType.Func> FindMethods(string wanted)
    {
        if (Methods.TryGetValue(wanted, out var mine)) return mine;
        if (Base?.FindMethods(wanted) is { Count: > 0 } inherited) return inherited;

        foreach (var trait in Traits)
            if (trait.FindMethods(wanted) is { Count: > 0 } provided) return provided;

        return [];
    }

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

    /// <summary>
    /// Where a requirement of this name is declared, and what shape it was declared with.
    /// Only the name was ever consulted before, so a class could satisfy
    /// <c>abstract func label(): String</c> with <c>func label(size: Int): Int</c> and the
    /// contract went unenforced in both directions.
    /// </summary>
    /// <summary>
    /// Where an inherited <em>implementation</em> of this name comes from, if there is one.
    /// Not what merely requires it: implementing an abstract member replaces nothing, so it
    /// is not an override and needs no keyword. Only a member with a body can be replaced.
    /// </summary>
    public ClassInfo? Replaces(string name)
    {
        for (var owner = Base; owner is not null; owner = owner.Base)
            if (owner.Methods.ContainsKey(name) && !owner.AbstractNames.Contains(name))
                return owner;

        foreach (var trait in Traits)
            if (trait.Methods.ContainsKey(name) && !trait.AbstractNames.Contains(name))
                return trait;

        return null;
    }

    public (ClassInfo Owner, EmType.Func Wanted)? Requirement(string name)
    {
        if (AbstractNames.Contains(name) && Methods.TryGetValue(name, out var own)
            && own.FirstOrDefault() is { } mine)
            return (this, mine);

        if (Base?.Requirement(name) is { } fromBase) return fromBase;

        foreach (var trait in Traits)
            if (trait.Requirement(name) is { } fromTrait) return fromTrait;

        return null;
    }

    /// <summary>The signature, not just the return type — a call site needs the parameters
    /// to check what it was handed.</summary>
    public EmType.Func? FindStaticMethod(string wanted) =>
        FindStaticMethods(wanted).FirstOrDefault();

    public List<EmType.Func> FindStaticMethods(string wanted) =>
        StaticMethods.TryGetValue(wanted, out var mine) ? mine
            : Base?.FindStaticMethods(wanted) ?? [];

    /// <summary>
    /// A type-level member read without parentheses: a static var's value, or a static
    /// method <em>itself</em> (§3.1). It used to give the method's return type, because a
    /// bare name was a call — that is what made <c>Make.tag</c> unusable as a value.
    /// </summary>
    public EmType? FindStatic(string wanted) =>
        StaticFields.TryGetValue(wanted, out var f) ? f
            : FindStaticMethods(wanted) is [var only] ? only
            : FindStaticMethods(wanted) is { Count: > 1 } set ? new EmType.Overloads(set)
            : Base?.FindStatic(wanted);

    public IEnumerable<string> StaticNames() =>
        StaticFields.Keys.Concat(StaticMethods.Keys).Concat(Base?.StaticNames() ?? []);

    public IEnumerable<string> MemberNames() =>
        Fields.Keys
            .Concat(Methods.Keys)
            .Concat(Base?.MemberNames() ?? [])
            .Concat(Traits.SelectMany(t => t.MemberNames()));
}
