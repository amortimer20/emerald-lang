namespace Emerald;

/// <summary>
/// A scope. Each block, function body, and lambda gets one, chained to its parent.
/// This is the object a REPL would hold onto and keep extending (§3.5), which is why
/// it is a real class rather than a dictionary buried in the interpreter.
/// </summary>
public sealed class Env(Env? parent = null)
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
        return parent?.TryAssign(name, value) ?? false;
    }
}

/// <summary>An Emerald error value, as produced by <c>Error("...")</c>.</summary>
public sealed class EmError(string message)
{
    public string Message => message;
    public override string ToString() => $"<Error: {message}>";
}

/// <summary>
/// Carries a thrown Emerald value up to the nearest <c>catch</c>. Distinct from
/// <see cref="RuntimeError"/>, which the interpreter raises itself — but a catch handles
/// both, so a failed <c>to_int</c> is catchable rather than only avoidable.
/// </summary>
public sealed class ThrownError(EmError value) : Exception(value.Message)
{
    public EmError Value { get; } = value;

    /// <summary>Filled in as it unwinds, so an uncaught throw names a line.</summary>
    public int Line { get; set; }
}

/// <summary>
/// Raised by <c>exit</c>. A signal rather than <c>Environment.Exit</c>, so the CLI stays
/// in control of how a run ends and the behaviour is testable.
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
