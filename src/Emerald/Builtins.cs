using System.Globalization;

namespace Emerald;

public interface ICallable
{
    object? Call(Interpreter interpreter, List<object?> args);
}

/// <summary>A growable sequence — Emerald has one, not C#'s list/List split (§3.7).</summary>
public sealed class EmList(List<object?> items)
{
    public List<object?> Items { get; } = items;
    public EmList() : this([]) { }
}

/// <summary>
/// A dictionary, in insertion order.
///
/// Order is kept deliberately. .NET's Dictionary makes no promise about it, and a
/// program whose output changes between runs for no visible reason is the worst thing to
/// hand a beginner — they cannot tell it from a bug in their own code. Python and
/// JavaScript both settled here for the same reason.
/// </summary>
public sealed class EmDict
{
    private readonly Dictionary<object, object?> _values = [];
    private readonly List<object> _order = [];

    public int Count => _order.Count;
    public IReadOnlyList<object> Keys => _order;

    public bool Has(object key) => _values.ContainsKey(key);
    public bool HasValue(object? value) => _order.Any(k => Equals(_values[k], value));

    public object? Get(object key) => _values.GetValueOrDefault(key);

    public void Set(object key, object? value)
    {
        if (!_values.ContainsKey(key)) _order.Add(key);
        _values[key] = value;
    }

    public void Remove(object key)
    {
        if (_values.Remove(key)) _order.RemoveAll(k => Equals(k, key));
    }

    public void Clear() { _values.Clear(); _order.Clear(); }

    public IEnumerable<object?> Values => _order.Select(k => _values[k]);
}

/// <summary>
/// A set, in insertion order — for the same reason a dictionary keeps one. Order is not
/// part of what a set <em>means</em>, which is exactly why it must not be allowed to vary
/// between runs: a difference with no cause is unattributable.
/// </summary>
public sealed class EmSet
{
    private readonly HashSet<object> _members = [];
    private readonly List<object> _order = [];

    public int Count => _order.Count;
    public IReadOnlyList<object> Members => _order;

    public bool Has(object value) => _members.Contains(value);

    public void Add(object value)
    {
        if (_members.Add(value)) _order.Add(value);
    }

    public void Remove(object value)
    {
        if (_members.Remove(value)) _order.RemoveAll(m => Equals(m, value));
    }

    public void Clear() { _members.Clear(); _order.Clear(); }

    public static EmSet Of(IEnumerable<object?> values)
    {
        var set = new EmSet();
        foreach (var value in values)
            set.Add(value ?? throw new RuntimeError("nothing cannot be a set member."));
        return set;
    }
}

/// <summary>
/// A built-in namespace of free functions, reached as <c>Math.sqrt(2.0)</c>. Distinct
/// from a user module (a file with no class line) only in being written in C#.
/// </summary>
public sealed class EmModule(string name, Dictionary<string, Func<List<object?>, object?>> members)
{
    public string Name => name;
    public IReadOnlyDictionary<string, Func<List<object?>, object?>> Members => members;

    public override string ToString() => $"<module {name}>";
}

/// <summary>An inclusive range, <c>1..5</c>.</summary>
public sealed record EmRange(long Start, long End) : IEnumerable<long>
{
    public IEnumerator<long> GetEnumerator()
    {
        if (Start <= End) for (long i = Start; i <= End; i++) yield return i;
        else for (long i = Start; i >= End; i--) yield return i;
    }

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() =>
        GetEnumerator();
}

/// <summary>
/// Kernel functions and the sprinkles (§3.7). Everything here is reachable by typing
/// '.', which is the point — no global len(x)-shaped functions operating on a receiver.
/// </summary>
public static class Builtins
{
    public static readonly Dictionary<string, Func<List<object?>, object?>> Kernel = new()
    {
        ["print"] = args =>
        {
            Console.WriteLine(args.Count == 0 ? "" : Display(args[0]));
            return null;
        },
        ["read_line"] = args =>
        {
            if (args.Count > 0) Console.Write(Display(args[0]));

            // At end of input there is no line. Returning "" would surface later as a
            // confusing "not a number" from whatever parsed it — an error about the wrong
            // thing. Say what actually happened instead.
            return Console.ReadLine() ?? throw new RuntimeError(
                "There is no more input to read.",
                "read_line reached the end of the input. That happens when piped input "
                + "runs out, or when you press Ctrl+D (Ctrl+Z on Windows).");
        },
        ["random"] = args =>
        {
            long lo = AsInt(args[0], "random");
            long hi = AsInt(args[1], "random");

            if (lo > hi)
                throw new RuntimeError(
                    $"random({lo}, {hi}) has no numbers to choose from.",
                    "The first number must not be larger than the second.");

            return (long)Random.Shared.NextInt64(lo, hi + 1);
        },

        // Builds an error value to throw. `throw "oops"` wraps a String in one of these
        // automatically, so the shorthand and the long form mean the same thing.
        ["Error"] = args => new EmError(args.Count > 0 ? Display(args[0]) : ""),

        // Stops the program. `exit` alone means success; `exit(1)` reports a failure.
        ["exit"] = args =>
            throw new ExitSignal(args.Count > 0 ? (int)AsInt(args[0], "exit") : 0),
    };

    /// <summary>
    /// Built-in modules. <c>sqrt</c> lives here rather than on <c>Float</c> because it
    /// replaces no syntax — it is arithmetic, and §3.7's rule sends that to a module.
    /// </summary>
    public static readonly Dictionary<string, EmModule> Modules = new()
    {
        // The kernel, reachable by name as well as bare (§3.3). Exactly the same functions
        // — Kernel is the dictionary above, not a copy of it, so the two spellings cannot
        // drift apart.
        ["Kernel"] = new EmModule("Kernel", Kernel),

        ["Math"] = new EmModule("Math", new()
        {
            ["pi"] = _ => Math.PI,
            ["e"] = _ => Math.E,
            ["sqrt"] = args => Math.Sqrt(AsNumber(args[0], "sqrt")),
            ["pow"] = args => Math.Pow(AsNumber(args[0], "pow"), AsNumber(args[1], "pow")),
            ["min"] = args => Smaller(args[0], args[1]),
            ["max"] = args => Larger(args[0], args[1]),
        }),
    };

    // Written as statements, not a ternary: C# unifies a ternary's branches, so
    // `cond ? longValue : doubleValue` quietly widens the long and Math.min(3, 9)
    // comes back as 3.0. Two Ints in must give an Int out.
    private static object Smaller(object? a, object? b)
    {
        if (a is long x && b is long y) return Math.Min(x, y);
        return Math.Min(AsNumber(a, "min"), AsNumber(b, "min"));
    }

    private static object Larger(object? a, object? b)
    {
        if (a is long x && b is long y) return Math.Max(x, y);
        return Math.Max(AsNumber(a, "max"), AsNumber(b, "max"));
    }

    public static object? InvokeMethod(
        Interpreter interpreter, object? target, string name, List<object?> args)
    {
        if (target is EmModule module)
        {
            if (module.Members.TryGetValue(name, out var member)) return member(args);
            throw new RuntimeError($"No member named {name} on {module.Name}.");
        }

        // A present value simply is itself, whichever of these you ask.
        if (target is not null && name is "or" or "must") return target;
        return Dispatch(interpreter, target, name, args);
    }

    private static object? Dispatch(
        Interpreter interpreter, object? target, string name, List<object?> args) =>
        target switch
        {
            long i => IntMethod(interpreter, i, name, args),
            double d => FloatMethod(d, name, args),
            string s => StringMethod(s, name, args),
            EmRange r => RangeMethod(interpreter, r, name, args),
            EmList a => ListMethod(interpreter, a, name, args),
            EmDict d => DictMethod(interpreter, d, name, args),
            EmSet t => SetMethod(interpreter, t, name, args),
            EmEnumValue v => name switch
            {
                "name" => v.Name,
                "to_string" => v.ToString(),
                _ => throw new RuntimeError($"No method named {name} on {v.Type}.")
            },
            EmError e => name switch
            {
                "message" => e.Message,
                "to_string" => e.Message,
                _ => throw new RuntimeError($"No method named {name} on Error.")
            },
            bool b => BoolMethod(b, name),

            // .or and .must are the only things you may ask of nothing (§3.2).
            null when name == "or" => args[0],
            null when name == "must" => throw new RuntimeError(
                "This is nothing, and .must() said it would not be.",
                "Check it against nothing first, or use .or(...) for a fallback."),
            null => throw new RuntimeError(
                $"Cannot call {name} on nothing.",
                "Check the value before using it, or supply a fallback with .or(...)"),

            _ => throw new RuntimeError($"No method named {name} on {TypeName(target)}.")
        };

    // ---- Set ------------------------------------------------------------

    private static object? SetMethod(
        Interpreter interp, EmSet set, string name, List<object?> args)
    {
        switch (name)
        {
            case "count": return (long)set.Count;
            case "empty?": return set.Count == 0;
            case "contains?": return args[0] is { } v && set.Has(v);
            case "to_list": return new EmList([.. set.Members]);
            case "clear": set.Clear(); return null;

            case "add":
                set.Add(args[0] ?? throw new RuntimeError("nothing cannot be a set member."));
                return null;

            case "remove":
                if (args[0] is { } gone) set.Remove(gone);
                return null;

            case "union": return EmSet.Of(set.Members.Concat(Other(args).Members));
            case "intersect": return EmSet.Of(set.Members.Where(Other(args).Has));
            case "difference": return EmSet.Of(set.Members.Where(m => !Other(args).Has(m)));
            case "subset_of?": return set.Members.All(Other(args).Has);

            case "each":
            {
                var block = args.LastOrDefault() as ICallable
                    ?? throw new RuntimeError("each needs a block, like { item => ... }.");

                foreach (var member in set.Members.ToList()) block.Call(interp, [member]);
                return null;
            }
        }

        throw new RuntimeError($"No method named {name} on Set.");
    }

    private static EmSet Other(List<object?> args) =>
        args.FirstOrDefault() as EmSet
        ?? throw new RuntimeError("This takes another Set.");

    // ---- Dictionary -----------------------------------------------------

    private static object? DictMethod(
        Interpreter interp, EmDict dict, string name, List<object?> args)
    {
        switch (name)
        {
            case "count": return (long)dict.Count;
            case "empty?": return dict.Count == 0;
            case "keys": return new EmList([.. dict.Keys]);
            case "values": return new EmList([.. dict.Values]);
            case "clear": dict.Clear(); return null;

            case "has_key?": return dict.Has(Key(args[0]));
            case "has_value?": return dict.HasValue(args[0]);

            // Missing gives nothing rather than failing — a lookup that misses is the
            // ordinary case, which is why this returns V? and .or(...) is the idiom.
            case "get": return dict.Get(Key(args[0]));

            case "set": dict.Set(Key(args[0]), args[1]); return null;
            case "remove": dict.Remove(Key(args[0])); return null;

            case "each":
            {
                var block = args.LastOrDefault() as ICallable
                    ?? throw new RuntimeError(
                        "each needs a block, like { key, value => ... }.");

                // A copy of the keys, so writing to the dictionary inside the block ends
                // rather than looping — the same promise `for x in list` makes.
                foreach (var key in dict.Keys.ToList())
                    block.Call(interp, [key, dict.Get(key)]);

                return null;
            }
        }

        throw new RuntimeError($"No method named {name} on Dictionary.");
    }

    /// <summary>
    /// A key has to be something the lookup can hash. The checker already refuses any
    /// other type, so reaching here means a value arrived through an unchecked path.
    /// </summary>
    private static object Key(object? value) =>
        value ?? throw new RuntimeError(
            "nothing cannot be a dictionary key.",
            "A key has to be an Int, a Float, a String, or a Bool.");

    // ---- List -----------------------------------------------------------

    /// <summary>
    /// Removes the first item the language would call equal, rather than the first .NET
    /// would. Searching a list has to mean what <c>==</c> means, or a type that defines
    /// <c>equals?</c> gets one answer from <c>a == b</c> and the opposite from
    /// <c>list.contains?(b)</c> — which it did.
    /// </summary>
    private static bool RemoveSame(Interpreter interp, List<object?> items, object? wanted)
    {
        int at = items.FindIndex(x => interp.Same(x, wanted));
        if (at < 0) return false;
        items.RemoveAt(at);
        return true;
    }

    private static object? ListMethod(
        Interpreter interp, EmList list, string name, List<object?> args)
    {
        List<object?> items = list.Items;

        return name switch
        {
            // iterate / transform / select
            "each" => Each(interp, items, args),
            "map" => new EmList([.. items.Select(x => Block(args).Call(interp, [x]))]),
            "filter" => new EmList([.. items.Where(x => Truthy(Block(args).Call(interp, [x])))]),
            "reject" => new EmList([.. items.Where(x => !Truthy(Block(args).Call(interp, [x])))]),

            // search — find and first/last give back a maybe, because they can miss
            "find" => items.FirstOrDefault(x => Truthy(Block(args).Call(interp, [x]))),
            "index_of" => (long)items.FindIndex(x => interp.Same(x, args[0])),
            "contains?" => items.Any(x => interp.Same(x, args[0])),

            // test
            "any?" => args.Count > 0
                ? items.Any(x => Truthy(Block(args).Call(interp, [x])))
                : items.Count > 0,
            "all?" => items.All(x => Truthy(Block(args).Call(interp, [x]))),
            "empty?" => items.Count == 0,

            // reduce
            "reduce" => items.Aggregate(args[0], (acc, x) => Block(args).Call(interp, [acc, x])),
            "count" => (long)items.Count,
            "sum" => items.Aggregate(0L, (acc, x) => acc + (x is long i ? i : 0L)),
            "min" => items.Count == 0 ? null : items.Min(),
            "max" => items.Count == 0 ? null : items.Max(),

            // order
            "sort" => new EmList([.. items.OrderBy(x => x)]),
            "sort_by" => new EmList([.. items.OrderBy(x => Block(args).Call(interp, [x]))]),
            "reverse" => new EmList([.. Enumerable.Reverse(items)]),

            // access
            "first" => items.Count == 0 ? null : items[0],
            "last" => items.Count == 0 ? null : items[^1],
            "join" => string.Join(args.Count > 0 ? AsString(args[0], "join") : "",
                                  items.Select(Display)),

            // mutate
            "add" => Mutate(items, () => items.Add(args[0])),
            "remove" => Mutate(items, () => RemoveSame(interp, items, args[0])),
            "remove_at" => Mutate(items, () => items.RemoveAt((int)AsInt(args[0], "remove_at"))),
            "clear" => Mutate(items, items.Clear),

            // A set is written as a list and converted, since the braces a set
            // literal would want are a block and a trailing lambda here.
            "to_set" => EmSet.Of(items),

            _ => throw new RuntimeError($"No method named {name} on List.")
        };

        static object? Each(Interpreter interp, List<object?> items, List<object?> args)
        {
            var body = Block(args);
            foreach (var item in items) body.Call(interp, [item]);
            return null;
        }

        static object? Mutate(List<object?> items, Action action)
        {
            action();
            return null;
        }

        static ICallable Block(List<object?> args) =>
            args.LastOrDefault() as ICallable
            ?? throw new RuntimeError("This method needs a block, like { x => ... }.");
    }

    private static bool Truthy(object? value) => value switch
    {
        null => false,
        bool b => b,
        _ => true
    };

    // ---- Int ------------------------------------------------------------

    private static object? IntMethod(
        Interpreter interp, long value, string name, List<object?> args) => name switch
    {
        // Sprinkles: each replaces a loop or an awkward expression (§3.7).
        "times" => Repeat(interp, value, args, start: 0),
        "upto" => Iterate(interp, new EmRange(value, AsInt(args[0], "upto")), args[1]),
        "downto" => Iterate(interp, new EmRange(value, AsInt(args[0], "downto")), args[1]),
        "even?" => value % 2 == 0,
        "odd?" => value % 2 != 0,
        "zero?" => value == 0,
        "positive?" => value > 0,
        "negative?" => value < 0,
        "between?" => value >= AsInt(args[0], "between?") && value <= AsInt(args[1], "between?"),
        "clamp" => Math.Clamp(value, AsInt(args[0], "clamp"), AsInt(args[1], "clamp")),

        // Ordinary type API, not sprinkles.
        "abs" => Math.Abs(value),
        "to_string" => value.ToString(CultureInfo.InvariantCulture),
        "to_float" => (double)value,
        _ => throw new RuntimeError($"No method named {name} on Int.")
    };

    private static object? Repeat(Interpreter interp, long count, List<object?> args, long start)
    {
        var body = AsCallable(args.LastOrDefault(), "times");
        for (long i = start; i < start + count; i++) body.Call(interp, [i]);
        return null;
    }

    private static object? Iterate(Interpreter interp, EmRange range, object? callable)
    {
        var body = AsCallable(callable, "upto");
        foreach (long i in range) body.Call(interp, [i]);
        return null;
    }

    // ---- Float ----------------------------------------------------------

    private static object? FloatMethod(double value, string name, List<object?> args) =>
        name switch
        {
            "round" => (long)Math.Round(value, MidpointRounding.AwayFromZero),

            // A separate name rather than round(places), because the answer is a
            // different type: round gives a whole number and round_to gives a Float.
            // One name returning two types is an overload, which Emerald does not have
            // yet — and `to_int` / `to_int_or` / `to_int_maybe` already settle the shape.
            "round_to" => RoundTo(value, AsInt(args[0], "round_to")),
            "floor" => (long)Math.Floor(value),
            "ceil" => (long)Math.Ceiling(value),
            "abs" => Math.Abs(value),
            "zero?" => value == 0,
            "positive?" => value > 0,
            "negative?" => value < 0,
            "to_string" => Display(value),
            "to_int" => (long)value,
            _ => throw new RuntimeError($"No method named {name} on Float.")
        };

    private static double RoundTo(double value, long places)
    {
        // .NET rounds to at most 15 places and throws past that. A number rounded to a
        // negative place is a question with no answer rather than an edge case.
        if (places < 0 || places > 15)
            throw new RuntimeError(
                $"round_to({places}) has no meaning.",
                "Round to between 0 and 15 decimal places.");

        return Math.Round(value, (int)places, MidpointRounding.AwayFromZero);
    }

    // ---- String ---------------------------------------------------------

    private static object? StringMethod(string value, string name, List<object?> args) =>
        name switch
        {
            // Graphemes, not UTF-16 units, so this agrees with .chars() and with `for`
            // — three ways of asking the same question about the same string, which had
            // better not give three answers. .length gave 10 for a string those two called
            // 3, and it was the only name a String answered while every container said
            // count. Two names split by receiver type is the mistake Java is known for.
            "count" => (long)Graphemes(value).Count(),
            "empty?" => value.Length == 0,
            "upper" => value.ToUpperInvariant(),
            "lower" => value.ToLowerInvariant(),

            // Reversing by char tears an emoji into its halves and reassembles it
            // backwards, which is the same bug wearing a different hat.
            "reverse" => string.Concat(Graphemes(value).Reverse()),
            "trim" => value.Trim(),
            "contains?" => value.Contains(AsString(args[0], "contains?"), StringComparison.Ordinal),
            "starts_with?" => value.StartsWith(AsString(args[0], "starts_with?"), StringComparison.Ordinal),
            "ends_with?" => value.EndsWith(AsString(args[0], "ends_with?"), StringComparison.Ordinal),

            "to_int" => long.TryParse(value, out long parsed)
                ? parsed
                : throw new RuntimeError(
                    $"\"{value}\" is not a number.",
                    "Use .to_int_or(0) for a fallback, or .to_int_maybe() to get nothing."),

            "to_int_or" => long.TryParse(value, out long ok) ? ok : args[0],
            "to_int_maybe" => long.TryParse(value, out long m) ? m : null,
            "to_string" => value,

            "to_float" => double.TryParse(value, out double f)
                ? f
                : throw new RuntimeError(
                    $"\"{value}\" is not a number.",
                    "Use .to_float_or(0.0) for a fallback, or .to_float_maybe() to get nothing."),
            "to_float_or" => double.TryParse(value, out double fo) ? fo : args[0],
            "to_float_maybe" => double.TryParse(value, out double fm) ? fm : null,

            // The one §3.2 promised: strings are not integer-indexed, so this is how you
            // get characters. Graphemes, not UTF-16 units — an emoji is one character.
            "chars" => new EmList([.. Graphemes(value).Cast<object?>()]),

            "split" => new EmList([.. value
                .Split(AsString(args[0], "split"), StringSplitOptions.None)
                .Cast<object?>()]),

            "replace" => value.Replace(AsString(args[0], "replace"),
                                       AsString(args[1], "replace"),
                                       StringComparison.Ordinal),
            _ => throw new RuntimeError($"No method named {name} on String.")
        };

    // ---- Range / Bool ---------------------------------------------------

    private static object? RangeMethod(
        Interpreter interp, EmRange range, string name, List<object?> args) => name switch
    {
        "each" => Iterate(interp, range, args.LastOrDefault()),
        "count" => (long)range.Count(),
        "contains?" => range.Contains(AsInt(args[0], "contains?")),
        "first" => range.Start,
        "last" => range.End,
        _ => throw new RuntimeError($"No method named {name} on Range.")
    };

    private static object? BoolMethod(bool value, string name) => name switch
    {
        "to_string" => value ? "true" : "false",
        _ => throw new RuntimeError($"No method named {name} on Bool.")
    };

    // ---- helpers --------------------------------------------------------

    public static string Display(object? value) => value switch
    {
        null => "nothing",
        bool b => b ? "true" : "false",
        long i => i.ToString(CultureInfo.InvariantCulture),
        double d => d == Math.Floor(d) && !double.IsInfinity(d)
            ? d.ToString("0.0", CultureInfo.InvariantCulture)
            : d.ToString("R", CultureInfo.InvariantCulture),
        string s => s,
        EmRange r => $"{r.Start}..{r.End}",
        EmClass c => $"<class {c.Name}>",
        EmInstance i => $"<{i.Class.Name}>",
        EmList a => "[" + string.Join(", ", a.Items.Select(Display)) + "]",
        EmEnumValue v => v.ToString(),
        EmSet t => "{" + string.Join(", ", t.Members.Select(Display)) + "}",
        EmDict d => d.Count == 0 ? "[:]"
            : "[" + string.Join(", ", d.Keys.Select(k => $"{Display(k)}: {Display(d.Get(k))}")) + "]",
        EmModule m => $"<module {m.Name}>",
        EmError e => e.Message,
        ICallable => "<function>",
        _ => value.ToString() ?? ""
    };

    public static string TypeName(object? value) => value switch
    {
        null => "nothing",
        bool => "Bool",
        long => "Int",
        double => "Float",
        string => "String",
        EmRange => "Range",
        EmList => "List",
        EmDict => "Dictionary",
        EmSet => "Set",
        EmEnumValue v => v.Type,
        EmModule m => m.Name,
        EmError => "Error",
        EmClass c => $"class {c.Name}",
        EmInstance i => i.Class.Name,
        ICallable => "Function",
        _ => value.GetType().Name
    };

    /// <summary>
    /// A string's characters, for <c>for c in text</c>. The same graphemes
    /// <c>.chars</c> gives, so walking a string and indexing its <c>.chars</c> list can
    /// never disagree about what a character is.
    /// </summary>
    public static IEnumerable<object?> CharactersOf(string value) =>
        Graphemes(value).Cast<object?>();

    /// <summary>
    /// Splits into grapheme clusters, so an emoji or an accented letter counts as one
    /// character rather than the two or more UTF-16 units it occupies.
    /// </summary>
    private static IEnumerable<string> Graphemes(string value)
    {
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext()) yield return (string)enumerator.Current;
    }

    private static double AsNumber(object? value, string method) => value switch
    {
        long i => i,
        double d => d,
        _ => throw new RuntimeError($"{method} expected a number, got {TypeName(value)}.")
    };

    private static long AsInt(object? value, string method) => value switch
    {
        long i => i,
        double d => (long)d,
        _ => throw new RuntimeError($"{method} expected an Int, got {TypeName(value)}.")
    };

    private static string AsString(object? value, string method) => value is string s
        ? s
        : throw new RuntimeError($"{method} expected a String, got {TypeName(value)}.");

    private static ICallable AsCallable(object? value, string method) => value is ICallable c
        ? c
        : throw new RuntimeError($"{method} expected a block, like {method} {{ i => ... }}.");
}
