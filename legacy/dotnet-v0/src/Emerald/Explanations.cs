namespace Emerald;

/// <summary>
/// <c>emerald explain</c> — the worked examples behind the diagnostics (§3.5).
///
/// Bare invocation explains the last error, because making a stuck student transcribe an
/// error code is a tax on someone already stuck. And each explanation shows broken code
/// beside fixed code rather than prose about the concept: a beginner who is stuck cannot
/// use a definition, but can always use a diff.
/// </summary>
public static class Explanations
{
    public sealed record Explanation(string Title, string Broken, string Fixed, string Why);

    /// <summary>
    /// Where the last error's topic is remembered between two runs of the compiler.
    ///
    /// Deliberately outside the project. §3.5 says a new project is one file with nothing
    /// to mangle, and a tool that drops a state directory beside a student's code the
    /// first time they make a mistake breaks that promise for the worst possible reason.
    /// </summary>
    private static string StatePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "emerald", "last-error");

    /// <summary>
    /// Records what the compiler just complained about, or that it complained about
    /// something with no explanation written for it.
    ///
    /// A null topic must still be written down. Leaving the previous run's topic in place
    /// would make the next bare <c>emerald explain</c> answer a question nobody asked —
    /// and a confident explanation of the wrong mistake is worse for a stuck student than
    /// no explanation at all.
    /// </summary>
    public static void Remember(string? topic)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            File.WriteAllText(StatePath, topic ?? "");
        }
        catch (IOException)
        {
            // Remembering is a convenience. A read-only home directory is not a reason to
            // fail a compile that otherwise succeeded in reporting the real problem.
        }
        catch (UnauthorizedAccessException) { }
    }

    private static string? Recall()
    {
        try
        {
            return File.Exists(StatePath) ? File.ReadAllText(StatePath).Trim() : null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static int Run(string[] args)
    {
        string? wanted = args.FirstOrDefault(a => !a.StartsWith('-'));

        if (args.Contains("--list"))
        {
            Console.WriteLine("Things emerald can explain:");
            Console.WriteLine();
            foreach (var (topic, entry) in Known.OrderBy(e => e.Key))
                Console.WriteLine($"  {topic,-22} {entry.Title}");
            Console.WriteLine();
            Console.WriteLine("  emerald explain <name>");
            return 0;
        }

        if (wanted is null)
        {
            wanted = Recall();

            // Three different situations, and telling them apart is the point. Nothing
            // remembered means no error has happened yet; an empty topic means one did,
            // and no explanation has been written for it. Answering both with the same
            // sentence would tell a student who is looking at an error that they are not.
            if (wanted is null)
            {
                Console.WriteLine("There is no recent error to explain.");
                Console.WriteLine();
                Console.WriteLine("  emerald explain --list     what can be explained");
                Console.WriteLine("  emerald explain <name>     explain one of them");
                return 0;
            }

            if (wanted.Length == 0)
            {
                Console.WriteLine("The last error does not have an explanation written yet.");
                Console.WriteLine();
                Console.WriteLine("The message itself is what there is to go on. If it was");
                Console.WriteLine("not enough, that is worth saying — a message a reader");
                Console.WriteLine("cannot act on is a bug in the message.");
                Console.WriteLine();
                Console.WriteLine("  emerald explain --list     what can be explained");
                return 0;
            }
        }

        if (!Known.TryGetValue(wanted, out var explanation))
        {
            Console.Error.WriteLine($"There is no explanation written for '{wanted}' yet.");
            Console.Error.WriteLine();
            Console.Error.WriteLine("  emerald explain --list     what can be explained");
            return 66;
        }

        Console.WriteLine();
        Console.WriteLine(explanation.Title);
        Console.WriteLine();
        Console.WriteLine("  This does not work:");
        Console.WriteLine();
        Write(explanation.Broken, "      ");
        Console.WriteLine();
        Console.WriteLine("  This does:");
        Console.WriteLine();
        Write(explanation.Fixed, "      ");
        Console.WriteLine();
        Write(explanation.Why, "  ");
        Console.WriteLine();
        return 0;
    }

    /// <summary>Indents each line, leaving blank ones blank — an "empty" line carrying six
    /// spaces is invisible until it lands in a diff.</summary>
    private static void Write(string block, string indent)
    {
        foreach (var line in block.Split('\n'))
            Console.WriteLine(line.Length == 0 ? "" : indent + line);
    }

    public static readonly Dictionary<string, Explanation> Known = new()
    {
        ["maybe"] = new(
            "Reaching through a value that might be nothing",
            """
            var name: String? = nothing
            print(name.count())
            """,
            """
            var name: String? = nothing
            if name != nothing {
                print(name.count())
            }
            """,
            """
            A String? holds either a String or nothing, and nothing cannot be counted.
            Checking it first is what tells the compiler which one it has — after that
            check, name is an ordinary String for the rest of the block.

            When any answer will do, ask for one:  name.or("unknown").count()

            The check works on a name, not on a path, so a chain gets ?. instead. It
            reads through the ? and puts it back on the answer, stopping at the first
            step that is missing:

                print(user.address?.city?.name.or("unknown"))
            """),

        ["struct-immutable"] = new(
            "Changing a struct",
            """
            struct Point {
                var x: Int
                var y: Int
            }

            var p = Point(1, 2)
            p.x = 10
            """,
            """
            struct Point {
                var x: Int
                var y: Int

                func with_x(x: Int): Point {
                    return Point(x, self.y)
                }
            }

            var p = Point(1, 2)
            var moved = p.with_x(10)
            """,
            """
            A struct is a value, like a number. Changing one in place would change it
            everywhere it had been copied to, so building a new one is how a struct
            changes. A class is the type that changes in place.
            """),

        ["self-during-construction"] = new(
            "Using an object while it is still being built",
            """
            class Greeter {
                var name: String

                func shout(): String { return self.name.upper() }

                constructor() {
                    print(self.shout())
                    self.name = "ada"
                }
            }
            """,
            """
            class Greeter {
                var name: String

                func shout(): String { return self.name.upper() }

                constructor() {
                    self.name = "ada"
                }
            }

            var g = Greeter()
            print(g.shout())
            """,
            """
            A constructor's job is to give every field a value. Until it finishes, the
            object is half-built: a field declared String is holding nothing, whatever
            its type says.

            So a constructor may not call the object's own methods, and may not pass self
            anywhere. A method reads whatever fields it likes, and anything handed self
            can do the same. Both are available the moment the constructor returns, which
            is where the second version does them.

            The rule is flat rather than "once the fields are set" because a class can be
            extended. A base constructor that has assigned all of its own fields still
            knows nothing about the fields a subclass added below it, and a method call
            can land on that subclass's override.
            """),

        ["field-needs-value"] = new(
            "A field that never gets a value",
            """
            class Tag {
                var name: String
            }
            """,
            """
            class Tag {
                var name: String

                constructor(name: String) {
                    self.name = name
                }
            }
            """,
            """
            name is declared String, and a String is never nothing. With no constructor
            there is no moment when it could be given a value, so the promise could not
            be kept.

            Three ways out: assign it in a constructor, give it a value where it is
            declared (var name = "untitled"), or say it may be missing (var name: String?).
            """),

        ["assign-in-condition"] = new(
            "Using = where == was meant",
            """
            var n = 5
            if n = 3 {
                print("three")
            }
            """,
            """
            var n = 5
            if n == 3 {
                print("three")
            }
            """,
            """
            = gives a variable a value. == asks whether two values are the same.

            In many languages the first one is allowed inside an if, and quietly assigns
            instead of comparing. Emerald makes assignment a statement rather than an
            expression, so it cannot appear in a condition at all and the mistake cannot
            be written.
            """),

        ["operator-trait"] = new(
            "Using + on a type that has not defined it",
            """
            class Money {
                var cents: Int
                constructor(cents: Int) { self.cents = cents }
            }

            var total = Money(100) + Money(250)
            """,
            """
            class Money with Addable {
                var cents: Int
                constructor(cents: Int) { self.cents = cents }

                func add(other: Money): Money {
                    return Money(self.cents + other.cents)
                }
            }

            var total = Money(100) + Money(250)
            """,
            """
            An operator is a method here: a + b calls a.add(b). A type earns + by mixing
            in Addable and writing add, which is why operators stay findable by typing a
            dot — they are ordinary methods underneath.

            The others work the same way: Subtractable, Multipliable, Dividable,
            Equatable (equals?), Ordered (compare), Indexable (at).
            """),

        ["break-in-block"] = new(
            "break inside a block",
            """
            items.each { item =>
                break if item == "stop"
                print(item)
            }
            """,
            """
            for item in items {
                break if item == "stop"
                print(item)
            }
            """,
            """
            A block is a function, and break stops a loop rather than leaving a function.
            The loop above it is outside the block, so break has nothing here to stop.

            A for loop over the same items can use break and continue, because the loop
            and the break are then in the same function.
            """),

        ["loop-over"] = new(
            "Looping over something that is not a sequence",
            """
            var total = 10
            for n in total {
                print(n)
            }
            """,
            """
            for n in 1..total {
                print(n)
            }
            """,
            """
            for walks a range, a list, a set, and a string. A number is not a sequence
            of anything — 1..total is the range from one to that number.

            5.times { print("hi") } is the other way to repeat something a set number of
            times, when the count itself is not needed.

            A dictionary walks in pairs, so it takes two names:

                for (name, age) in people {
                    print("#{name} is #{age}")
                }
            """),

        ["list-type"] = new(
            "Writing a list type",
            """
            func total(xs: List): Int {
                return xs.sum()
            }
            """,
            """
            func total(xs: List<Int>): Int {
                return xs.sum()
            }
            """,
            """
            A list has to say what it holds. Without that the compiler cannot know what
            xs.sum() adds up, nor stop a list of strings being handed to it.

            Nesting works the same way: List<List<Int>> is a list of lists of numbers.
            """),

        ["dictionary-type"] = new(
            "Writing a dictionary type",
            """
            var scores: Dictionary = [:]
            """,
            """
            var scores: Dictionary<String, Int> = [:]

            scores["ada"] = 36
            print(scores["ada"].or(0))
            """,
            """
            A dictionary has to say what it maps to what: the key type first, then the
            value type.

            Looking one up gives back Int? rather than Int, because the key might not be
            there — which is the ordinary case for a lookup, not a mistake. .or(0) is how
            you say what to use when it is missing, and it is what makes counting read
            well:  counts[word] = counts[word].or(0) + 1
            """),

        ["set-type"] = new(
            "Making a set",
            """
            var seen: Set = []
            """,
            """
            var vowels = ["a", "e", "i", "o", "u"].to_set()
            var seen: Set<String> = [].to_set()

            print(vowels.contains?("e"))
            """,
            """
            A set has no literal of its own. The braces other languages use for one are
            a block and a trailing lambda here, and the bracket already belongs to lists —
            so a set is written as a list and converted with .to_set().

            It has to say what it holds, the same way a list does. Members are Int, Float,
            String, or Bool: finding a value again needs hashing.
            """),

        ["argument-type"] = new(
            "Passing the wrong kind of value",
            """
            func double(n: Int): Int {
                return n * 2
            }

            print(double("4"))
            """,
            """
            func double(n: Int): Int {
                return n * 2
            }

            print(double("4".to_int()))
            """,
            """
            double asks for an Int, and "4" is a String — the text of a number rather than
            a number. They look alike and behave differently: "4" * 2 is not 8.

            to_int() converts one and fails loudly if the text is not a number.
            to_int_or(0) supplies a fallback instead, and to_int_maybe() gives nothing.
            """),

        ["casing"] = new(
            "Names that read as the wrong kind of thing",
            """
            var playerName = "ana"
            class player_stats { }
            """,
            """
            var player_name = "ana"
            class PlayerStats { }
            """,
            """
            Emerald uses two casings and one rule: types are capitalized, and nothing else
            is. So a capitalized name reads as a type wherever it appears, and a reader
            never has to look a name up to know which kind of thing it is.

            This is a warning, not an error. The program runs; the name just says
            something about itself that is not true.
            """),
    };
}
