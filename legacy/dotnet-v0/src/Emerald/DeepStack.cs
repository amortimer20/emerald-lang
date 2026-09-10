using System.Runtime.ExceptionServices;

namespace Emerald;

/// <summary>
/// Runs a program on a thread with room to recurse.
///
/// A tree-walking interpreter spends host stack on every Emerald call, so how deep a
/// student's recursion may go is decided by the host thread rather than by the language.
/// On the default stack that ceiling was about two thousand calls, and crossing it killed
/// the process with a .NET stack dump — §3.6's promise broken in the loudest possible way,
/// on the one topic where a beginner writes runaway recursion on purpose.
///
/// The interpreter's own depth limit is what should stop a program. This is what makes
/// that limit reachable: give the thread enough room that the counter always fires first,
/// so the answer is a written message and is the same on every machine.
///
/// The size is reserved address space, not memory in use — pages are committed as the
/// stack actually grows, so a program that never recurses pays nothing for it.
/// </summary>
public static class DeepStack
{
    /// <summary>
    /// Room for the interpreter's depth limit with margin over it. A frame costs a few
    /// kilobytes and varies with how nested the expressions in it are, so the margin is
    /// generous on purpose: the failure this exists to prevent is silent and fatal, and
    /// the cost of over-reserving is address space nobody is using.
    /// </summary>
    public const int Bytes = 512 * 1024 * 1024;

    public static void Run(Action work)
    {
        ExceptionDispatchInfo? failure = null;

        var thread = new Thread(() =>
        {
            try { work(); }
            catch (Exception problem) { failure = ExceptionDispatchInfo.Capture(problem); }
        }, Bytes);

        thread.Start();
        thread.Join();

        // Rethrown on the caller's thread with its original stack, so every catch that
        // was written around the call still reads as though nothing had moved.
        failure?.Throw();
    }
}
