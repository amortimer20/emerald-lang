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

/// <summary>
/// An inclusive range, <c>1..5</c>. Counts up, and only up: <c>5..1</c> is empty.
///
/// It used to reverse itself, which made <c>0..(count - 1)</c> — the only spelling an
/// inclusive range has for "walk n items" — yield <c>{0, -1}</c> on an empty collection
/// and index out of bounds. Ruby and Python both answer this the same way, and choosing
/// inclusive ranges is what obliges the question to be answered at all.
/// </summary>
public sealed record EmRange(long Start, long End) : IEnumerable<long>
{
    public IEnumerator<long> GetEnumerator()
    {
        for (long i = Start; i <= End; i++) yield return i;
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
            case "contains?": return args[0] is { } v && set.Has(v);
            case "clear": set.Clear(); return null;
            case "superset_of?": return Other(args).Members.All(set.Has);

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

        }

        if (Shared.Contains(name)) return SharedMethod(interp, set, name, args);
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
            case "keys": return new EmList([.. dict.Keys]);
            case "values": return new EmList([.. dict.Values]);
            case "clear": dict.Clear(); return null;

            case "has_key?": return dict.Has(Key(args[0]));
            // Through the same == as everything else. It used to use .NET's Equals, so
            // a dictionary said it did not hold a struct that a list beside it found
            // without trouble — one question, two answers, decided by the container.
            case "has_value?": return dict.Values.Any(v => interp.Same(v, args[0]));

            // Missing gives nothing rather than failing — a lookup that misses is the
            // ordinary case, which is why this returns V? and .or(...) is the idiom.
            case "get": return dict.Get(Key(args[0]));

            case "set": dict.Set(Key(args[0]), args[1]); return null;
            case "remove": dict.Remove(Key(args[0])); return null;

        }

        if (Shared.Contains(name)) return SharedMethod(interp, dict, name, args);
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

        // Everything a set, range and dictionary also answers to lives in one place, so
        // the four containers cannot drift apart. What stays here is what is genuinely a
        // list's own: ordering, positional access, and mutation.
        if (Shared.Contains(name)) return SharedMethod(interp, list, name, args);

        return name switch
        {
            // search
            "index_of" => (long)items.FindIndex(x => interp.Same(x, args[0])),
            "contains?" => items.Any(x => interp.Same(x, args[0])),

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
            "remove_at" => Mutate(items, () => items.RemoveAt(Position(items, args[0]))),
            "clear" => Mutate(items, items.Clear),

            // A set is written as a list and converted, since the braces a set
            // literal would want are a block and a trailing lambda here.
            "to_set" => EmSet.Of(items),

            _ => throw new RuntimeError($"No method named {name} on List.")
        };

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
        "upto" => Iterate(interp, new EmRange(value, AsInt(args[0], "upto")), args[1], "upto"),
        "downto" => Iterate(interp, Descending(value, AsInt(args[0], "downto")), args[1], "downto"),
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

    private static object? Iterate(
        Interpreter interp, IEnumerable<long> steps, object? callable, string named)
    {
        var body = AsCallable(callable, named);
        foreach (long i in steps) body.Call(interp, [i]);
        return null;
    }

    /// <summary>
    /// <c>5.downto(1)</c>. Both names used to build a range and walk it, so the range's
    /// own direction decided what happened and neither name meant anything: 3.upto(1)
    /// counted down and 5.downto(9) counted up. Now upto is ascending because a range is,
    /// and this is the one thing in the language that descends.
    /// </summary>
    private static IEnumerable<long> Descending(long from, long to)
    {
        for (long i = from; i >= to; i--) yield return i;
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

    /// <summary>
    /// How a Float is written. The rule is that <strong>anything printed should be
    /// something that could have been typed</strong> — which already held for
    /// <c>nothing</c>, <c>true</c> and <c>Suit.HEARTS</c>, and did not hold here.
    ///
    /// It used to switch on whether the value happened to be whole: a whole one printed
    /// in full, so 1e21 arrived as twenty-two digits, and everything else went through
    /// "R", which produced <c>1E-07</c> — a spelling the language could not read back,
    /// with an uppercase E that was never Emerald syntax at all.
    ///
    /// The large threshold is not arbitrary. Past 2^53 a double no longer holds every
    /// whole number, so printing one as a plain integer claims a precision it does not
    /// have; 1e16 is the first round power of ten beyond it. The small one follows
    /// Python, which switches at the same place.
    /// </summary>
    private static string Float(double d)
    {
        if (double.IsInfinity(d) || double.IsNaN(d))
            return d.ToString(CultureInfo.InvariantCulture);

        double size = Math.Abs(d);
        if (size != 0 && (size >= 1e16 || size < 1e-4)) return Scientific(d);

        // "R" and nothing else. The whole-number branch used to format with "0.0", which
        // is fifteen significant digits and therefore not round-trippable: 9007199254740992
        // printed as 9007199254740990, a wrong answer to a value that had been typed
        // exactly. A Float is shown at whatever length it takes to read back as itself.
        string text = d.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.', StringComparison.Ordinal) ? text : text + ".0";
    }

    /// <summary>
    /// <c>1.0e-7</c> — the exponent form the scanner accepts, so the round trip closes.
    ///
    /// Built from "R" rather than from a fixed width. "E16" asks for seventeen digits
    /// whether or not they mean anything, so 0.0000001 came out as 9.9999999999999995e-8
    /// — true of the double, and not what anybody wrote or wants to read. "R" gives the
    /// shortest text that reads back as the same value, which is the right length by
    /// definition.
    /// </summary>
    private static string Scientific(double d)
    {
        string text = d.ToString("R", CultureInfo.InvariantCulture);

        int e = text.IndexOf('E', StringComparison.Ordinal);
        if (e >= 0)
        {
            string found = text[..e];
            if (!found.Contains('.', StringComparison.Ordinal)) found += ".0";
            return $"{found}e{int.Parse(text[(e + 1)..], CultureInfo.InvariantCulture)}";
        }

        // "R" switches to exponent form at its own threshold, not at this one, so 1e16
        // arrives here as seventeen plain digits. Where the two disagree, the language's
        // threshold wins and the point is placed here — by moving characters rather than
        // by arithmetic, so nothing is rounded on the way.
        bool negative = text.StartsWith('-');
        if (negative) text = text[1..];

        int point = text.IndexOf('.', StringComparison.Ordinal);
        string digits = point < 0 ? text : text.Remove(point, 1);
        if (point < 0) point = text.Length;

        int first = 0;
        while (first < digits.Length && digits[first] == '0') first++;
        if (first == digits.Length) return negative ? "-0.0" : "0.0";

        string significant = digits[first..].TrimEnd('0');
        string mantissa = significant.Length == 1
            ? significant + ".0"
            : significant[..1] + "." + significant[1..];

        return $"{(negative ? "-" : "")}{mantissa}e{point - first - 1}";
    }

    /// <summary>
    /// <c>replace</c>, with the one argument .NET refuses caught first. An empty string to
    /// look for matches everywhere and nowhere, so <c>Replace</c> throws — which arrived as
    /// "this is a bug in Emerald" for a program that had merely asked something meaningless.
    /// </summary>
    private static string Replaced(string value, string looking, string instead)
    {
        if (looking.Length == 0)
            throw new RuntimeError(
                "replace needs something to look for, and this is an empty string.",
                "An empty string sits between every character, so there is no one place "
                + "to put the replacement.");

        return value.Replace(looking, instead, StringComparison.Ordinal);
    }

    /// <summary>
    /// A position in a list, checked. Without this <c>remove_at</c> handed the number
    /// straight to .NET and an out-of-range one came back as an ArgumentOutOfRangeException
    /// — reported as "this is a bug in Emerald", which for an ordinary mistake in an
    /// ordinary program is both alarming and false. Indexing had this guard; the one
    /// method that removes by index did not.
    /// </summary>
    private static int Position(List<object?> items, object? given)
    {
        long i = AsInt(given, "remove_at");

        if (i < 0 || i >= items.Count)
            throw new RuntimeError(
                $"Index {i} is outside this list, which holds {items.Count} item(s).",
                items.Count == 0
                    ? "The list is empty."
                    : $"Valid positions run from 0 to {items.Count - 1}.");

        return (int)i;
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

            // Width, which the language had no way to ask for at all — so a board, a
            // table or a menu had nowhere to start, and every project wrote these four
            // for itself. Counted in graphemes, so they agree with .count() and with
            // `for`: a hand-written pad that measures the .NET way lines an accented
            // column up wrong, which is the bug .reverse had.
            "pad_left" => Pad(value, args, "pad_left", before: true),
            "pad_right" => Pad(value, args, "pad_right", before: false),
            "pad_center" => PadCenter(value, args),
            "repeat" => Repeated(value, AsInt(args[0], "repeat")),

            // Whole-string questions: is every character one of these. One character is
            // the common call and reads best — `typed.letter?()` — and the same rule
            // answers "is this whole thing digits" before .to_int().
            "letter?" => EveryCharacter(value, char.IsLetter),
            "digit?" => EveryCharacter(value, char.IsDigit),

            // blank? is the exception, and deliberately: it asks whether there is nothing
            // here to read, and an empty string is the clearest case of that. The other
            // two need a character to be true of.
            "blank?" => Graphemes(value).All(g => g.All(char.IsWhiteSpace)),
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

            "split" => Split(value, AsString(args[0], "split")),

            "replace" => Replaced(value, AsString(args[0], "replace"),
                                  AsString(args[1], "replace")),
            _ => throw new RuntimeError($"No method named {name} on String.")
        };

    // ---- Iterable -------------------------------------------------------

    /// <summary>
    /// The members every container answers to, implemented once over whatever it yields.
    ///
    /// Before this, only <c>List</c> had them: <c>(1..10).map</c>, <c>set.filter</c> and
    /// <c>scores.any?</c> were all errors, so a student who learned the vocabulary on a
    /// list met a wall on every other container — not a different name to learn, just a
    /// wall. §3.7 fenced sprinkles away from collections on the grounds that they already
    /// carried the core twenty; only one of the four did.
    /// </summary>
    public static readonly string[] Shared =
    [
        "each", "map", "filter", "reject", "find", "any?", "all?", "count", "empty?",
        "reduce", "sum", "min", "max", "to_list",
    ];

    /// <summary>
    /// What a container hands its block, one call at a time. A list, set or range gives
    /// one value; a dictionary gives a key and a value, matching the two-parameter block
    /// its own <c>each</c> has always taken.
    /// </summary>
    private static IEnumerable<List<object?>> Rows(object? target) => target switch
    {
        EmList list => list.Items.ToList().Select(x => new List<object?> { x }),
        EmSet set => set.Members.ToList().Select(x => new List<object?> { x }),
        EmRange range => range.Select(n => new List<object?> { n }),

        // A copy of the keys, so writing to the dictionary inside the block ends rather
        // than looping — the same promise `for x in list` and `dict.each` both make.
        EmDict dict => dict.Keys.ToList().Select(k => new List<object?> { k, dict.Get(k) }),

        _ => throw new RuntimeError($"{TypeName(target)} cannot be walked.")
    };

    /// <summary>
    /// Puts kept rows back into the shape they came from. <c>filter</c> on a set is a set
    /// and on a dictionary is a dictionary, because narrowing a container should not
    /// change what it is. A range rebuilds as a list: 1..10 filtered to the evens is not
    /// a range, and pretending otherwise would need a representation Emerald does not
    /// have. <c>map</c> is a list from every receiver, since its answers may collide or
    /// be unhashable and it is not narrowing anything.
    /// </summary>
    private static object? Rebuild(object? original, IEnumerable<List<object?>> kept) =>
        original switch
        {
            EmSet => EmSet.Of(kept.Select(row => row[0])),
            EmDict => DictOf(kept),
            _ => new EmList([.. kept.Select(row => row[0])]),
        };

    private static EmDict DictOf(IEnumerable<List<object?>> rows)
    {
        var built = new EmDict();
        foreach (var row in rows) built.Set(row[0]!, row[1]);
        return built;
    }

    /// <summary>
    /// A dictionary yields pairs, and a pair is not a value Emerald can hand back — there
    /// is no tuple type. So the members that return an <em>element</em> are unavailable on
    /// one, and say so rather than inventing a shape.
    /// </summary>
    private static object? Single(object? target, List<object?> row, string name) =>
        target is EmDict
            ? throw new RuntimeError(
                $"{name} is not available on a Dictionary.",
                "A dictionary walks in pairs, and a pair is not a value on its own. "
                + "Ask its .keys() or .values() instead.")
            : row[0];

    private static object? SharedMethod(
        Interpreter interp, object? target, string name, List<object?> args)
    {
        var rows = Rows(target);
        bool Test(List<object?> row) => Truthy(Block(args).Call(interp, row));

        switch (name)
        {
            case "each":
            {
                foreach (var row in rows) Block(args).Call(interp, row);
                return null;
            }

            case "map": return new EmList([.. rows.Select(r => Block(args).Call(interp, r))]);
            case "filter": return Rebuild(target, rows.Where(Test));
            case "reject": return Rebuild(target, rows.Where(r => !Test(r)));

            case "any?": return args.Count > 0 ? rows.Any(Test) : rows.Any();
            case "all?": return rows.All(Test);
            case "count": return (long)rows.Count();
            case "empty?": return !rows.Any();

            case "find":
                return rows.FirstOrDefault(Test) is { } hit ? Single(target, hit, "find") : null;

            case "reduce":
                return rows.Aggregate(
                    args[0], (acc, row) => Block(args).Call(interp, [acc, .. row]));

            case "to_list": return new EmList([.. rows.Select(r => Single(target, r, "to_list"))]);

            // Sums whatever it is given rather than only whole numbers. Adding a list of
            // Floats used to answer 0, because the old fold started at 0L and dropped
            // anything that was not a long on the floor.
            case "sum": return Total(rows.Select(r => Single(target, r, "sum")));

            case "min":
            case "max":
            {
                var values = rows.Select(r => Single(target, r, name)).ToList();
                if (values.Count == 0) return null;
                return name == "min" ? values.Min() : values.Max();
            }
        }

        throw new RuntimeError($"No method named {name} on {TypeName(target)}.");

        static ICallable Block(List<object?> args) =>
            args.LastOrDefault() as ICallable
            ?? throw new RuntimeError("This method needs a block, like { x => ... }.");
    }

    /// <summary>
    /// Adds whole numbers as whole numbers and anything with a fraction as a Float, so a
    /// list of Ints still sums to an Int and a list of Floats no longer sums to zero.
    /// </summary>
    private static object? Total(IEnumerable<object?> values)
    {
        long whole = 0;
        double fractional = 0;
        bool anyFloat = false;

        foreach (var value in values)
        {
            if (value is long i) whole += i;
            else if (value is double d) { fractional += d; anyFloat = true; }
        }

        // Cast both arms: without them C# unifies the ternary to double, and every sum
        // of whole numbers came back as 5050.0.
        return anyFloat ? (object)(whole + fractional) : (object)whole;
    }

    // ---- Range / Bool ---------------------------------------------------

    private static object? RangeMethod(
        Interpreter interp, EmRange range, string name, List<object?> args) => name switch
    {
        "contains?" => range.Contains(AsInt(args[0], "contains?")),
        "first" => range.Start,
        "last" => range.End,
        _ => Shared.Contains(name)
            ? SharedMethod(interp, range, name, args)
            : throw new RuntimeError($"No method named {name} on Range.")
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
        double d => Float(d),
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
    /// <summary>
    /// Whether every character satisfies <paramref name="ok"/>, tested on the first unit of
    /// each grapheme — so an accented letter is a letter, since its base is one, and an
    /// emoji is not. An empty string is false: there is no character to be true of.
    /// </summary>
    private static bool EveryCharacter(string value, Func<char, bool> ok) =>
        value.Length > 0 && Graphemes(value).All(g => ok(g[0]));

    private static string Pad(string value, List<object?> args, string method, bool before)
    {
        string filled = Fill(Padding(args, method), Missing(value, args, method));
        return before ? filled + value : value + filled;
    }

    private static string PadCenter(string value, List<object?> args)
    {
        int missing = Missing(value, args, "pad_center");
        if (missing <= 0) return value;

        // The odd character goes on the right, so a column of centered text keeps its
        // left edge straight — which is the edge anyone lining one up is looking at.
        string fill = Padding(args, "pad_center");
        int left = missing / 2;
        return Fill(fill, left) + value + Fill(fill, missing - left);
    }

    private static string Padding(List<object?> args, string method) =>
        args.Count > 1 ? AsString(args[1], method) : " ";

    private static int Missing(string value, List<object?> args, string method) =>
        (int)AsInt(args[0], method) - Graphemes(value).Count();

    /// <summary>
    /// Enough of <paramref name="fill"/> to cover <paramref name="count"/> characters,
    /// repeating it and cutting it off part-way if it does not divide evenly.
    /// </summary>
    private static string Fill(string fill, int count)
    {
        if (count <= 0) return "";
        if (fill.Length == 0)
            throw new RuntimeError("The padding cannot be an empty string.",
                                   "Leave it out for spaces, or give a character to use.");

        List<string> made = [];
        while (made.Count < count)
            foreach (var grapheme in Graphemes(fill))
            {
                if (made.Count == count) break;
                made.Add(grapheme);
            }

        return string.Concat(made);
    }

    private static string Repeated(string value, long times)
    {
        if (times < 0)
            throw new RuntimeError($"repeat needs zero or more, not {times}.");

        var built = new System.Text.StringBuilder();
        for (long i = 0; i < times; i++) built.Append(value);
        return built.ToString();
    }

    /// <summary>
    /// Splits on a separator, and on an empty separator gives every character.
    ///
    /// .NET returns the whole string unsplit for an empty separator, which is the one
    /// answer nobody predicts: asked to split on nothing, it did nothing. Every character
    /// is what the request plainly means, and what a reader coming from Ruby or
    /// JavaScript already expects. It agrees with <c>chars()</c> by construction, so
    /// there is no second definition of what a character is.
    /// </summary>
    private static EmList Split(string value, string separator) =>
        new([.. (separator.Length == 0 ? Graphemes(value)
                                       : value.Split(separator, StringSplitOptions.None))
             .Cast<object?>()]);

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
