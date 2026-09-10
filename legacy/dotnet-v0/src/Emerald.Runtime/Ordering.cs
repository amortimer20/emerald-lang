namespace Emerald.Runtime;

/// <summary>
/// The one order Emerald sorts by, and the one <c>&lt;</c> answers with.
///
/// These were two orders until recently. <c>sort</c> went through
/// <c>Comparer&lt;object&gt;.Default</c>, which for strings is culture-sensitive, so
/// <c>["b", "A", "a", "B"].sort()</c> gave <c>a, A, b, B</c> while <c>"a" &lt; "B"</c>
/// answered false -- and the sorted one changed with the machine's locale, so the same
/// program could print different output on a different computer.
///
/// The typed methods are what emitted code calls: a backend that knows it is comparing
/// two strings has no reason to box them. <see cref="Values"/> is the adapter the
/// interpreter needs, where a value's type is only known at run time. Both go through the
/// same rules, which is the entire point of the split.
/// </summary>
public static class Ordering
{
    /// <summary>
    /// Ordinal, never culture-sensitive. Uppercase sorts before lowercase because that is
    /// where the code points are, and the answer is the same in every locale.
    /// </summary>
    public static int Compare(string a, string b) => string.CompareOrdinal(a, b);

    /// <summary>
    /// A total order over numbers, which is what sorting needs and is not what the
    /// operators answer. NaN sits below every number here; <c>nan &lt; 1</c> is still
    /// false, because sorting and comparing are different questions.
    /// </summary>
    public static int Compare(double a, double b) => a.CompareTo(b);

    public static int Compare(long a, long b) => a.CompareTo(b);

    public static int Compare(bool a, bool b) => a.CompareTo(b);

    /// <summary>
    /// The same rules reached through <c>object?</c>, for a caller holding values whose
    /// types it does not know until it looks -- which is the interpreter, and no one else.
    ///
    /// Returns null rather than throwing when the pair has no order. Refusing is a
    /// language decision that wants a written diagnostic naming both types, and messages
    /// belong to the compiler: this library ships to every program and should not carry
    /// the vocabulary for talking to a student about their mistake.
    /// </summary>
    public static int? TryCompare(object? a, object? b) => (a, b) switch
    {
        (string x, string y) => Compare(x, y),
        (long x, long y) => Compare(x, y),
        (bool x, bool y) => Compare(x, y),
        (long or double, long or double) => Compare(AsDouble(a), AsDouble(b)),

        // Anything that orders itself, which is how a user type's compare is reached and
        // how a wrapped .NET type comes for free -- DateTime and Version already implement
        // this, and would need a shim under any rule that asked for an interface of ours.
        //
        // Last on purpose. string, long and double all implement IComparable too, and
        // string's is culture-sensitive: reaching it before the arms above would put back
        // the locale-dependent ordering those arms exist to remove.
        // Guarded on the two being the same kind of thing. Written open at first, and the
        // C# caller caught it within the minute: an int is IComparable, so 1 against 2.5
        // stopped answering "no order" and started throwing "Object must be of type
        // Int32" out of the BCL -- a raw host exception where this returns null by
        // contract. A comparer that throws instead of declining is worse than one that
        // declines too often.
        (IComparable x, not null) when a.GetType().IsInstanceOfType(b)
            => Math.Sign(x.CompareTo(b)),

        _ => null,
    };

    private static double AsDouble(object? v) => v is long i ? i : (double)v!;

    /// <summary>
    /// <see cref="TryCompare"/> as an <c>IComparer</c>, so it can be handed to
    /// <c>OrderBy</c>, <c>Min</c> and <c>Max</c> directly. The <c>onIncomparable</c>
    /// callback is how the caller supplies its own diagnostic without this library
    /// knowing how to write one.
    /// </summary>
    public sealed class Values(Func<object?, object?, Exception> onIncomparable)
        : IComparer<object?>
    {
        public int Compare(object? a, object? b) =>
            TryCompare(a, b) ?? throw onIncomparable(a, b);
    }
}
