namespace Emerald.Runtime;

/// <summary>
/// The first thing emitted code calls, and deliberately the narrowest thing in this
/// library so far.
///
/// <c>print</c> in the interpreter is <c>Console.WriteLine(Display(value))</c>, where
/// <see cref="object"/>Display formats every kind of value Emerald has -- numbers, lists,
/// a user instance's own <c>to_string</c>, and so on. None of that formatting lives here
/// yet. This exists only to give the very first compiled program something real to call
/// rather than a bare <c>Console.WriteLine</c> baked into the emitter, so that when
/// <c>Display</c>'s rules do move into this library, the call site the emitter already
/// generates does not have to change.
/// </summary>
public static class IO
{
    /// <summary>Text, already formatted, written the way <c>print</c> writes it.</summary>
    public static void Print(string text) => Console.WriteLine(text);
}
