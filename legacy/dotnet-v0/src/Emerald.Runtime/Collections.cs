namespace Emerald.Runtime;

/// <summary>
/// Collection operations that take a block, expressed so that both the interpreter and
/// emitted code can call them.
///
/// A block is a <see cref="Func{T, TResult}"/> here and nothing else. That is the whole
/// contract, and it is not much of a decision: a compiled Emerald lambda <em>is</em> a
/// CLR delegate, so emitted code passes one with no adapter at all. The interpreter's own
/// block is an <c>ICallable</c> whose signature takes an <c>Interpreter</c> — the calling
/// convention that must not travel into this library — so the interpreter wraps it, once,
/// at the call site.
///
/// What this does not settle is the other kind of re-entry: a value's <em>own</em> method,
/// as <c>to_string</c>, <c>equals?</c>, <c>compare</c>, <c>at</c> and <c>set_at</c> are.
/// Those are a different shape and a real decision, and they are left alone here.
/// </summary>
public static class Collections
{
    /// <summary>A block: one value in, one value out. What a compiled lambda already is.</summary>
    public delegate object? Block(object? value);

    /// <summary>
    /// <c>sort_by</c>. Ordered by the key the block gives back, using the one comparer
    /// <c>&lt;</c> answers with, so sorting by a key agrees with comparing that key.
    ///
    /// Stable, and deliberately: two rows with equal keys keep the order they arrived in,
    /// which is what makes sorting twice by two keys do what a reader expects. LINQ's
    /// OrderBy is stable and CIL offers nothing that is, so an emitter reaching for
    /// Array.Sort would quietly lose the property.
    /// </summary>
    public static List<object?> SortBy(IEnumerable<object?> items, Block key,
                                       IComparer<object?> order) =>
        Sorted(() => [.. items.OrderBy(x => key(x), order)]);

    /// <summary><c>sort</c>: the values themselves, by the same order.</summary>
    public static List<object?> Sort(IEnumerable<object?> items, IComparer<object?> order) =>
        Sorted(() => [.. items.OrderBy(x => x, order)]);

    /// <summary>
    /// Runs a sort and lets the caller's own error out of it.
    ///
    /// .NET wraps anything a comparer throws in an <c>InvalidOperationException</c> saying
    /// "Failed to compare two elements in the array" &mdash; so a written diagnostic about
    /// a type that cannot be ordered arrived as <em>"this is a bug in Emerald, not in your
    /// program"</em>, which was both unreadable and untrue. The comparer's own exception is
    /// the one the caller built and the one worth showing.
    /// </summary>
    private static List<object?> Sorted(Func<List<object?>> sort)
    {
        try { return sort(); }
        catch (InvalidOperationException wrapped) when (wrapped.InnerException is { } real)
        {
            throw real;
        }
    }

}
