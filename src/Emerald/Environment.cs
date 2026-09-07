namespace Emerald;

/// <summary>
/// A scope. Each block, function body, and lambda gets one, chained to its parent.
/// This is the object a REPL would hold onto and keep extending (§3.5), which is why
/// it is a real class rather than a dictionary buried in the interpreter.
/// </summary>
/// <param name="shared">
/// A dictionary this scope reads and writes through as if the names were its own, checked
/// after its own bindings and before its parent's. A module's top-level code uses it to
/// reach the file's own variables: those became static fields when §3.3 turned the file
/// into a class, but the code was written as a file's body and must still see them.
/// Sharing the dictionary rather than copying it means a static method called from the
/// initializer sees the same values, in both directions.
/// </param>
public sealed class Env(Env? parent = null, Dictionary<string, object?>? shared = null)
{
    private readonly Dictionary<string, object?> _values = [];
    private readonly HashSet<string> _constants = [];

    public void Declare(string name, object? value, bool isConst = false)
    {
        _values[name] = value;
        if (isConst) _constants.Add(name);
    }

    public bool TryGet(string name, out object? value)
    {
        if (_values.TryGetValue(name, out value)) return true;
        if (shared is not null && shared.TryGetValue(name, out value)) return true;
        if (parent is not null) return parent.TryGet(name, out value);
        value = null;
        return false;
    }

    /// <summary>Assigns to an existing binding, walking outward. Returns false if the
    /// name is unknown; throws if it names a const.</summary>
    public bool TryAssign(string name, object? value)
    {
        if (_values.ContainsKey(name))
        {
            if (_constants.Contains(name))
                throw new RuntimeError($"{name} is a const and cannot be reassigned.");
            _values[name] = value;
            return true;
        }

        if (shared is not null && shared.ContainsKey(name))
        {
            shared[name] = value;
            return true;
        }

        return parent?.TryAssign(name, value) ?? false;
    }
}

/// <summary>
/// Carries a thrown Emerald error up to the nearest <c>catch</c>. Distinct from
/// <see cref="RuntimeError"/>, which the interpreter raises itself — but a catch handles
/// both, so a failed <c>to_int</c> is catchable rather than only avoidable.
/// </summary>
public sealed class ThrownError(EmInstance value)
    : Exception(Builtins.Display(value.Fields.GetValueOrDefault(Prelude.MessageField)))
{
    /// <summary>
    /// The error itself, so a typed catch can ask what class it is. An ordinary
    /// instance of a prelude class rather than a value of its own kind, which is what
    /// lets a program declare its own errors with nothing but <c>extends</c>.
    /// </summary>
    public EmInstance Value { get; } = value;

    /// <summary>
    /// Whether a failed <c>assert</c> raised this. It is thrown like any other error so
    /// a test runner and a catch both see it, but what to tell the reader differs: an
    /// assertion that did not hold means the program is wrong, and suggesting they wrap
    /// it in a try would be advice to hide it.
    /// </summary>
    public bool FromAssertion { get; init; }

    /// <summary>Filled in as it unwinds, so an uncaught throw names a line.</summary>
    public int Line { get; set; }
}

/// <summary>
/// Raised by <c>exit</c>. A signal rather than <c>Environment.Exit</c>, so the CLI stays
/// in control of how a run ends and the behavior is testable.
/// </summary>
public sealed class ExitSignal(int code) : Exception
{
    public int Code { get; } = code;
}

public sealed class RuntimeError(string message, string? hint = null) : Exception(message)
{
    public string? Hint { get; } = hint;

    /// <summary>Filled in by the interpreter as the error propagates out, so a runtime
    /// message can point at a line the way a compile-time one does (§3.6).</summary>
    public int Line { get; set; }
}
