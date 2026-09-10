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

        ## A type that can walk what it holds, one thing at a time.
        ##
        ## each is required and gives every other method here for free — map, filter, find,
        ## count, to_list and contains? are all written once, against each alone, and every
        ## class that mixes this in gets all of them without writing any itself. That is the
        ## whole trick List, Dictionary and Set already have built in, now available to a
        ## type you write.
        ##
        ## Item is this trait's one open question — what each hands its block, one at a
        ## time. Whatever implements Iterable says what Item is, and every method below
        ## reads correctly the moment that answer exists.
        trait Iterable {
            type Item

            ## What narrowing this gives back. Defaulted rather than required, because the
            ## answer is only interesting to a type that can hold a narrowed version of
            ## itself: a Set stays a Set, and everything else — a Deck, a Range, whatever
            ## someone writes next — becomes a list, since a trait cannot build one of them
            ## and a list is the honest shape for what it can build. Written in terms of
            ## Item, so binding one answers both.
            type Filtered = List<Item>

            abstract func each(step: func(Item))

            ## Runs f on every item and collects what it gives back. R is never written at
            ## a call site — deck.map { c => c.name } answers for it, from what the block
            ## itself returns.
            func map<R>(f: func(Item): R): List<R> {
                var result: List<R> = []
                self.each { item => result.add(f(item)) }
                return result
            }

            func filter(keep: func(Item): Bool): Filtered {
                var result: List<Item> = []
                self.each { item => result.add(item) if keep(item) }
                return result
            }

            ## The other half of filter, and it answers Filtered for the same reason:
            ## narrowing a collection should not change what it is.
            func reject(drop: func(Item): Bool): Filtered {
                var result: List<Item> = []
                self.each { item => result.add(item) if not drop(item) }
                return result
            }

            ## K is whatever the block answers. Nothing here says it has to be a type a
            ## dictionary can key on, because inside this trait K means nothing yet — the
            ## ordinary key rules ask once the call has said what K is.
            func group_by<K>(key: func(Item): K): Dictionary<K, List<Item>> {
                var groups: Dictionary<K, List<Item>> = [:]
                self.each { item =>
                    var bucket = groups[key(item)].or([])
                    bucket.add(item)
                    groups[key(item)] = bucket
                }
                return groups
            }

            func find(matches: func(Item): Bool): Item? {
                for item in self.to_list() {
                    return item if matches(item)
                }
                return nothing
            }

            ## Walks the whole collection rather than stopping at the first answer, because
            ## a block cannot break out of an each (§3.1) — the same reason find has to
            ## build a list before it can return early. Correct either way; the cost is
            ## work, not answers.
            func any?(matches: func(Item): Bool): Bool {
                var found = false
                self.each { item =>
                    found = true if matches(item)
                }
                return found
            }

            func all?(matches: func(Item): Bool): Bool {
                var every = true
                self.each { item =>
                    every = false if not matches(item)
                }
                return every
            }

            func empty?(): Bool {
                return self.count() == 0
            }

            ## R is what the running total is, and it is never written down: reduce(0) says
            ## Int and reduce("") says String. Unlike map's own R, which the block answers
            ## for, this one has to be settled before the block is looked at — the block
            ## takes an R as well as giving one back, so nothing in it can be checked until
            ## the starting value has said what R means.
            func reduce<R>(start: R, step: func(R, Item): R): R {
                var total = start
                self.each { item => total = step(total, item) }
                return total
            }


            ## The index goes last, so a block wanting only the item is unchanged and
            ## naming the position is opt-in. Ruby and JavaScript both put it there.
            func each_with_index(step: func(Item, Int)) {
                var at = 0
                self.each { item =>
                    step(item, at)
                    at += 1
                }
            }

            func take(many: Int): Filtered {
                var result: List<Item> = []
                self.each { item => result.add(item) if result.count() < many }
                return result
            }

            func drop(many: Int): Filtered {
                var result: List<Item> = []
                var seen = 0
                self.each { item =>
                    result.add(item) if seen >= many
                    seen += 1
                }
                return result
            }

            func count(): Int {
                var total = 0
                self.each { item => total += 1 }
                return total
            }

            ## Ranked by something about each item rather than by the item itself, which is
            ## why these live here and min and max live on Sortable: what has to have an
            ## order is K, the block's answer, not Item. A deck of cards with no order of
            ## its own still has a highest card by value.
            func max_by<K: Ordered>(of: func(Item): K): Item? {
                var best: Item? = nothing
                var top: K? = nothing
                self.each { item =>
                    var key = of(item)
                    if best == nothing or key > top.must() {
                        best = item
                        top = key
                    }
                }
                return best
            }

            func min_by<K: Ordered>(of: func(Item): K): Item? {
                var best: Item? = nothing
                var bottom: K? = nothing
                self.each { item =>
                    var key = of(item)
                    if best == nothing or key < bottom.must() {
                        best = item
                        bottom = key
                    }
                }
                return best
            }

            func to_list(): List<Item> {
                var result: List<Item> = []
                self.each { item => result.add(item) }
                return result
            }

            ## Walks rather than asking find, and the difference is not style.
            ##
            ## find answers with the item or with nothing, so "nothing came back" has to
            ## stand in for "nothing matched" — and those are the same answer when Item is
            ## itself nullable. A collection holding nothing then reported that it did not
            ## hold it, while the list beside it said it did: one question, two answers,
            ## decided by which family you inherited. find's ambiguity is inherent and
            ## shared with every language that has the method — C# spells it
            ## FirstOrDefault — so the rule is that membership must never be built on it.
            func contains?(target: Item): Bool {
                var found = false
                self.each { item =>
                    found = true if item == target
                }
                return found
            }
        }

        ## A collection whose items have an order, which is what min and max need and what
        ## walking alone cannot give. Mixed in beside Iterable rather than folded into it,
        ## because most collections have no order and should not be asked to invent one —
        ## a deck of cards walks perfectly well without being sortable.
        ##
        ## `type Item: Ordered` refines what Iterable already declared: the name is still
        ## Iterable's, and this says what an answer to it has to be.
        trait Sortable with Iterable {
            type Item: Ordered

            func max(): Item? {
                var best: Item? = nothing
                self.each { item =>
                    best = item if best == nothing or item > best.must()
                }
                return best
            }

            func min(): Item? {
                var best: Item? = nothing
                self.each { item =>
                    best = item if best == nothing or item < best.must()
                }
                return best
            }
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

    /// <summary>
    /// What the primitives implement, written beside the traits themselves so there is one
    /// place to read what <c>+</c> means rather than a declaration here and a rule in the
    /// checker that can drift from it.
    ///
    /// None of this is new behavior — <c>1 + 2</c>, <c>"a" + "b"</c> and <c>"apple" &lt;
    /// "banana"</c> all worked before any of it was written down. What was missing was the
    /// type system agreeing: <c>func f(x: Ordered)</c> refused an <c>Int</c>, so the same
    /// question had one answer from the operator and the opposite from the checker.
    ///
    /// <c>Bool</c> is deliberately not <c>Ordered</c>. There is no meaningful order on true
    /// and false, and inventing one for symmetry is the kind of tidiness that has to be
    /// explained to a student later.
    ///
    /// Nothing here is <c>Indexable</c>: §3.2 keeps strings out of the index syntax on
    /// purpose, and the containers that are indexable are not primitives.
    /// </summary>
    public static readonly Dictionary<string, HashSet<string>> PrimitiveTraits = new()
    {
        ["Int"] = ["Addable", "Subtractable", "Multipliable", "Dividable", "Ordered", "Equatable"],
        ["Float"] = ["Addable", "Subtractable", "Multipliable", "Dividable", "Ordered", "Equatable"],

        // Concatenation is the only arithmetic a string has. Multiplying one is Ruby's
        // `"ab" * 3`, which Emerald spells `"ab".repeat(3)` — a method, not an operator.
        ["String"] = ["Addable", "Ordered", "Equatable"],

        ["Bool"] = ["Equatable"],
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
        "Indexable", "Iterable", "Sortable",
        "Error",
    ];
}
