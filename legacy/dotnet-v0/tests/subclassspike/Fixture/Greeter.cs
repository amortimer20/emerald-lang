namespace Fixture;

/// <summary>
/// A stand-in for "some existing C# library" -- the thing §5.2's first milestone is
/// about subclassing from Emerald. Abstract on purpose: Greet has no C# body at all, so
/// the only way ShoutGreeting can produce anything is by calling into whatever overrides
/// it, and if that override is Emerald-authored, running ShoutGreeting is C# calling
/// back into Emerald. That round trip, not the subclassing alone, is what the milestone
/// names.
/// </summary>
public abstract class Greeter
{
    public abstract string Greet();

    public string ShoutGreeting() => Greet().ToUpperInvariant() + "!";
}
