using Emerald.Runtime;

// A plain C# program using Emerald's runtime library, with no compiler anywhere.
//
// It exists to hold the boundary rather than to test the values -- the golden cases
// already check those against the interpreter. What this checks is that the boundary is
// real: this project references Emerald.Runtime and nothing else, so if a rule the
// backend needs drifts back into the compiler, this stops compiling. Discipline would
// not have caught that; a reference list does.
//
// It is also the shape emitted code will have. Every call below is a static method on a
// plain type taking plain values, which is what CIL can emit directly -- no interpreter,
// no boxed argument list, no syntax tree.

Console.WriteLine(Numbers.Round(2.5));
Console.WriteLine(Numbers.Round(3.5));
Console.WriteLine(Numbers.Round(-2.5));
Console.WriteLine(Numbers.Truncate(7.9));
Console.WriteLine(Numbers.Truncate(-7.9));
Console.WriteLine(Numbers.RoundTo(3.14159, 2));

Console.WriteLine(Numbers.FloorDiv(7, 2));
Console.WriteLine(Numbers.FloorDiv(-7, 2));
Console.WriteLine(Numbers.FloorDiv(7, -2));
Console.WriteLine(Numbers.FloorDiv(-7, -2));
Console.WriteLine(Numbers.FloorMod(7, 2));
Console.WriteLine(Numbers.FloorMod(-7, 2));
Console.WriteLine(Numbers.FloorMod(7, -2));
Console.WriteLine(Numbers.FloorMod(-7, -2));
Console.WriteLine(Numbers.FloorDiv(9223372036854775807, 3));

Console.WriteLine(Numbers.Text(1.0));
Console.WriteLine(Numbers.Text(0.5));
Console.WriteLine(Numbers.Text(1.0e-7));
Console.WriteLine(Numbers.Text(1.0e20));
Console.WriteLine(Numbers.Text(0.1 + 0.2));

// Ordinal: lowercase sorts after uppercase, so "a" is greater than "B".
Console.WriteLine(Ordering.Compare("a", "B") > 0);
Console.WriteLine(Ordering.Compare("Z", "a") < 0);

// The ordering the interpreter sorts by, reached through the typed method rather than
// through the object? adapter -- which is how emitted code will reach it.
string[] names = ["b", "A", "a", "B"];
Array.Sort(names, Ordering.Compare);
Console.WriteLine(string.Join(",", names));

// A block-taking operation, with the block as a plain delegate. This is the shape
// emitted code passes with no adapter at all, a compiled lambda already being one --
// and the interpreter is the side that has to wrap, since its own block carries a
// calling convention this library deliberately does not know about.
object?[] words = ["pear", "fig", "banana"];
// The key is cast to long, not left as int: an Emerald Int is Int64, and the comparer
// refuses anything else rather than converting quietly.
var byLength = Collections.SortBy(words, w => (long)((string)w!).Length,
                                  new Ordering.Values((a, b) => new InvalidOperationException()));
Console.WriteLine(string.Join(",", byLength));

// And the adapter, for a caller that does not know the types until it looks. It is
// deliberately strict about what an Emerald value is: an Int is Int64, so a C# `int`
// is not one and gets no order rather than a quiet conversion. The interpreter only
// ever holds long and double, and a backend should be equally explicit.
Console.WriteLine(Ordering.TryCompare(1L, 2.5) < 0);
Console.WriteLine(Ordering.TryCompare(1, 2.5) is null);
Console.WriteLine(Ordering.TryCompare("x", 1L) is null);
