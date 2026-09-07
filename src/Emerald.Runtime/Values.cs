namespace Emerald.Runtime;

/// <summary>
/// How the runtime asks a value to speak for itself.
///
/// It calls the CLR's own <c>ToString</c>, and that is the whole mechanism. An emitted
/// Emerald class is a real .NET type with a real override, so <c>print</c> in compiled
/// code is an ordinary virtual call the CLR dispatches — no hook, no host object, no
/// interface of ours in anyone's metadata. A C# consumer writing
/// <c>Console.WriteLine(money)</c> gets what an Emerald <c>print</c> gives, because it is
/// the same call.
///
/// It replaces a static mutable <c>Func</c> that whichever interpreter was constructed
/// last installed at startup: a process-wide singleton, wrong the moment two programs are
/// open at once, and impossible to emit against at all.
///
/// <strong>This exists as a named function rather than as a bare <c>ToString()</c> at each
/// site on purpose.</strong> Wrapping a .NET library means Emerald will one day hold
/// values nobody here wrote — a <c>FileInfo</c>, a Unity <c>GameObject</c> — and they
/// answer this call already, which is the reason the CLR's own method was chosen over an
/// interface they could never implement. If a foreign value ever needs a different rule,
/// there is one place to put it.
/// </summary>
public static class Values
{
    /// <summary>
    /// How deep a chain of these may go. A <c>to_string</c> that prints the value it was
    /// asked about calls itself forever, and a stack overflow is not something a student
    /// can read. The limit belongs here rather than in the interpreter because emitted
    /// code can write the same loop.
    /// </summary>
    public const int MaxDepth = 64;

    private static int _depth;

    /// <summary>
    /// A value's own text. <c>onTooDeep</c> supplies the diagnostic, for the same reason
    /// the comparer takes one: the sentence a reader gets is the compiler's business, not
    /// a shipped library's.
    /// </summary>
    public static string Text(object? value, Func<object?, Exception> onTooDeep)
    {
        if (_depth >= MaxDepth) throw onTooDeep(value);

        _depth++;
        try { return value?.ToString() ?? ""; }
        finally { _depth--; }
    }
}
