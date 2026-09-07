namespace Emerald;

/// <summary>
/// The operator traits and the Error base class (§3.2), written in Emerald and parsed
/// like any other source.
///
/// They could have been synthesised as <see cref="ClassInfo"/> and <see cref="EmClass"/>
/// objects directly, which would be about the same amount of code. Writing them as source
/// is better for two reasons: the contracts go through the same trait machinery user code
/// does — so a bug in trait resolution shows up here rather than hiding behind a parallel
/// path — and there is exactly one place to read to find out what <c>+</c> means.
///
/// Every method is abstract. These traits provide nothing; they only name what a type must
/// supply before an operator will reach it. That is Rust's std::ops model, and it is why
/// operators stay discoverable by typing <c>.</c> — they are ordinary methods underneath.
/// </summary>
public static class Prelude
{
    /// <summary>
    /// Angle brackets keep this from colliding with any real file, since a diagnostic
    /// reports the file a statement came from.
    /// </summary>
    public const string FileName = "<operators>";

    /// <summary>
    /// Parameters are left unannotated deliberately. The trait cannot say "the same type
    /// as the implementor" without a Self type, which Emerald does not have; annotating
    /// them as anything else would be a lie. The implementing class declares real types,
    /// and the checker holds the operands to <em>those</em> — so `money + 5` is still an
    /// error, it is just caught against Money.add rather than against Addable.
    /// </summary>
    public const string Source = """
        ## Something that went wrong. Every error a program declares extends this one.
        ##
        ## `throw "text"` is shorthand for `throw Error("text")`, so the short form and the
        ## long form build the same value. A catch with no type named on it catches this
        ## and everything below it, which is why the untyped form still means "anything
        ## that can go wrong".
        ##
        ## @param message what went wrong, in words the reader of the output can act on
        class Error {
            var message: String

            constructor(message: String) {
                self.message = message
            }

            ## The message, so an error reads as its own text where a String is wanted.
            func to_string(): String {
                return self.message
            }
        }

        ## Values that can be joined with +.
        trait Addable {
            abstract func add(other)
        }

        ## Values that can be taken away from one another with -.
        trait Subtractable {
            abstract func subtract(other)
        }

        ## Values that can be scaled with *.
        trait Multipliable {
            abstract func multiply(other)
        }

        ## Values that can be split with /.
        trait Dividable {
            abstract func divide(other)
        }

        ## Values that can be compared for sameness with == and !=.
        ##
        ## Only equals? is implemented. != is always its negation, so the two cannot
        ## disagree — a pair of definitions that contradict each other is a bug this
        ## language will not let you write.
        trait Equatable {
            abstract func equals?(other): Bool
        }

        ## Values that can be ordered with <, >, <=, and >=.
        ##
        ## One method answers all four. compare returns a negative number if self comes
        ## first, zero if the two sort alike, and a positive number if self comes after.
        trait Ordered {
            abstract func compare(other): Int
        }

        ## Values that can be reached by position with a[i].
        ##
        ## at is required and gives reading. Writing — a[i] = value — is enabled by also
        ## defining set_at(index, value), the same way a var with only a get body is
        ## read-only until a set body is added. A collection that should not be written
        ## to simply leaves set_at out.
        trait Indexable {
            abstract func at(index)
        }
        """;

    /// <summary>The prelude's source split into lines, so a diagnostic can quote it.</summary>
    public static string[] Lines => Source.Replace("\r\n", "\n").Split('\n');

    /// <summary>
    /// Parsed fresh each time rather than cached. The statements become part of a specific
    /// program's tree, and sharing mutable AST nodes between runs is the kind of economy
    /// that buys nothing and costs an afternoon.
    /// </summary>
    public static List<Stmt> Parse()
    {
        var scanner = new Scanner(Source, FileName);
        var parser = new Parser(scanner.ScanTokens(), FileName, scanner.DocComments);
        var statements = parser.ParseProgram();

        // The prelude is fixed source that ships with the compiler. If it does not parse,
        // that is a defect in the compiler and no user program can be trusted to run.
        if (scanner.Diagnostics.Count > 0 || parser.Diagnostics.Count > 0)
            throw new InvalidOperationException(
                "The operator prelude failed to parse — this is a compiler defect.");

        return statements;
    }

    /// <summary>
    /// Operator to method name. The single source of truth: the checker uses it to decide
    /// what to look for, the interpreter to decide what to call, and the diagnostics to
    /// name the trait that is missing.
    /// </summary>
    public static readonly Dictionary<TokenType, (string Method, string Trait)> Operators = new()
    {
        [TokenType.Plus] = ("add", "Addable"),
        [TokenType.Minus] = ("subtract", "Subtractable"),
        [TokenType.Star] = ("multiply", "Multipliable"),
        [TokenType.Slash] = ("divide", "Dividable"),
    };

    public const string EqualsMethod = "equals?";
    public const string EquatableTrait = "Equatable";
    public const string CompareMethod = "compare";
    public const string OrderedTrait = "Ordered";

    /// <summary>The base of every error. Named here because the checker, the
    /// interpreter and the printer all have to agree on which class it is.</summary>
    public const string ErrorType = "Error";

    /// <summary>The one field an Error carries, and the text a catch reports.</summary>
    public const string MessageField = "message";

    public const string AtMethod = "at";
    public const string SetAtMethod = "set_at";
    public const string IndexableTrait = "Indexable";

    /// <summary>Type names the prelude owns, so a program cannot quietly redefine them.</summary>
    public static readonly HashSet<string> TypeNames =
    [
        "Addable", "Subtractable", "Multipliable", "Dividable", "Equatable", "Ordered",
        "Indexable",
        "Error",
    ];
}
