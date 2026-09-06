namespace Emerald;

/// <summary>
/// An error stops the program; a warning does not. §2.6 makes warnings a design surface
/// rather than an afterthought — the compiler is the most patient teacher in the room —
/// which is only possible once a diagnostic can be something other than fatal.
/// </summary>
public enum Severity { Error, Warning }

public sealed record Diagnostic(
    string File, int Line, string Message, string? Hint = null,
    Severity Severity = Severity.Error,

    /// <summary>Which worked example `emerald explain` should show for this. Null where
    /// none is written yet, which is most of them and is said out loud rather than
    /// papered over.</summary>
    string? Topic = null);

/// <summary>
/// The written shape of a callable: <c>func(Int): String</c>. A function's type is its
/// header with the name removed, so there is no second grammar to learn — and the return
/// type is optional here for the same reason it is optional on a declaration.
/// </summary>
public sealed record FuncRef(List<TypeRef> Params, TypeRef? Returns);

/// <summary>
/// A written type. <c>Arguments</c> holds the type arguments of a compiler-owned generic;
/// <c>Function</c> is set instead when the type is a callable, and then <c>Name</c> is the
/// <c>func</c> keyword itself, kept only so a diagnostic has a line to point at.
/// </summary>
public sealed record TypeRef(Token Name, bool Nullable, List<TypeRef>? Arguments = null,
                             FuncRef? Function = null);

public sealed record Param(Token Name, TypeRef? Type, Expr? Default);

/// <summary>
/// <c>@export</c>, <c>@name("Any")</c> — declarative, compiler-known, and generating no
/// code (§3.8). Named Attr rather than Attribute because .NET's implicit usings already
/// bring System.Attribute into scope, and two things called Attribute in one file is a
/// puzzle nobody needs to solve twice.
/// </summary>
public sealed record Attr(Token Name, Expr? Argument);

/// <summary>One <c>key: value</c> pair of a dictionary literal.</summary>
public sealed record Entry(Expr Key, Expr Value);

// ---- expressions --------------------------------------------------------

public abstract record Expr
{
    /// <summary>
    /// A constant. <c>Line</c> exists only so a diagnostic can point at one: an expression
    /// made entirely of literals — <c>if true then "a" else 42</c> — otherwise carried no
    /// token anywhere, and the error came out at line 0 with no source line to quote.
    /// </summary>
    public sealed record Literal(object? Value, int Line = 0) : Expr;

    /// <summary>"a #{b} c" — alternating literal and expression parts.</summary>
    public sealed record Interpolation(List<Expr> Parts) : Expr;

    public sealed record Variable(Token Name) : Expr;
    public sealed record Grouping(Expr Inner) : Expr;
    public sealed record Unary(Token Op, Expr Right) : Expr;
    public sealed record Binary(Expr Left, Token Op, Expr Right) : Expr;

    /// <summary>
    /// <c>value is Dog</c>. Asks what a value actually is at runtime, and narrows the
    /// name to that type for the branch where the answer is yes — the same machinery
    /// the <c>nothing</c> check has always used, pointed at a second question.
    /// </summary>
    public sealed record TypeTest(Expr Value, Token Keyword, TypeRef Type) : Expr;

    /// <summary>
    /// <c>animal as Dog</c>, giving <c>Dog?</c>. The same question <c>is</c> asks, answered
    /// as a value rather than as a narrowing — for the places narrowing cannot reach, since
    /// it is recorded against a name and a field is not one.
    /// </summary>
    public sealed record TypeCast(Expr Value, Token Keyword, TypeRef Type) : Expr;

    /// <summary>Short-circuits, so it cannot share Binary's evaluation.</summary>
    public sealed record Logical(Expr Left, Token Op, Expr Right) : Expr;

    /// <summary>if c then a else b — the expression form. `else` is mandatory (§3.1).</summary>
    public sealed record IfExpr(Expr Condition, Expr Then, Expr Else) : Expr;

    public sealed record RangeExpr(Expr Start, Expr End) : Expr;

    /// <summary>[1, 2, 3]</summary>
    public sealed record ListLiteral(Token Bracket, List<Expr> Items) : Expr;

    /// <summary>
    /// <c>["a": 1, "b": 2]</c>, and <c>[:]</c> for an empty one. Shares the bracket with
    /// a list rather than taking <c>{ }</c>, which is a block and a trailing lambda here —
    /// <c>{ x: 1 }</c> could not be told from <c>{ x =&gt; 1 }</c> without lookahead nobody
    /// should have to do. Swift solves it the same way, for the same reason.
    /// </summary>
    public sealed record DictLiteral(Token Bracket, List<Entry> Entries) : Expr;

    /// <summary>a[0] — lowered through the Indexable trait once traits exist (§3.2).</summary>
    public sealed record Index(Expr Target, Token Bracket, Expr Position) : Expr;
    public sealed record Lambda(List<Param> Params, List<Stmt> Body) : Expr;

    /// <summary>
    /// Property or method access: <c>dog.name</c>, <c>5.times</c>. <c>Optional</c> is the
    /// <c>?.</c> form, where a receiver that is nothing gives nothing back unread.
    /// </summary>
    public sealed record Get(Expr Target, Token Name, bool Optional = false) : Expr;

    /// <summary>
    /// A call. <c>Trailing</c> is the trailing-lambda sprinkle: <c>1.upto(5) { i => ... }</c>
    /// and <c>5.times { ... }</c> both land here.
    /// </summary>
    /// <summary>
    /// <c>TypeArgs</c> is the <c>&lt;Dog&gt;</c> of <c>animal.as&lt;Dog&gt;()</c>: type
    /// arguments written at a call site. Consuming a generic method, never declaring one
    /// — §5.3 defers declaring, and nothing here introduces a type parameter.
    /// </summary>
    public sealed record Call(
        Expr Callee, List<Expr> Args, Lambda? Trailing,
        List<TypeRef>? TypeArgs = null) : Expr;
}

// ---- statements ---------------------------------------------------------

public abstract record Stmt
{
    public sealed record VarDecl(
        Token Name, TypeRef? Type, Expr? Init, bool IsConst,
        bool IsStatic = false,
        List<Stmt>? Getter = null, List<Stmt>? Setter = null,
        List<Attr>? Attributes = null) : Stmt;

    /// <summary>Assignment is a statement, never an expression (§3.1) — so
    /// <c>if x = 5 { }</c> cannot parse, and the =/== bug is unrepresentable.</summary>
    public sealed record Assign(Expr Target, Token Op, Expr Value) : Stmt;

    public sealed record ExprStmt(Expr Expression) : Stmt;

    /// <summary>`else if` is represented as an Else branch holding a single If.</summary>
    public sealed record If(Expr Condition, List<Stmt> Then, List<Stmt>? Else) : Stmt;

    public sealed record While(Expr Condition, List<Stmt> Body) : Stmt;
    /// <summary>
    /// <c>for x in xs</c>, and <c>for (k, v) in pairs</c> when <c>Second</c> is present.
    /// A pair is worth having only if it can be taken apart, and the loop is where taking
    /// one apart is most often wanted.
    /// </summary>
    public sealed record For(
        Token Variable, Expr Iterable, List<Stmt> Body, Token? Second = null) : Stmt;

    /// <summary>
    /// <c>var (name, score) = best</c>. Two names bound from one pair.
    ///
    /// Its own statement rather than a VarDecl carrying a list, because almost everything
    /// a VarDecl can be -- a property with a get body, a static, an annotated field --
    /// is meaningless here, and folding it in would mean writing "not on a destructure"
    /// into a dozen checks that currently do not have to think about it.
    /// </summary>
    public sealed record PairDecl(
        Token First, Token Second, Expr Init, bool IsConst) : Stmt;
    /// <summary>A null <c>Body</c> means abstract: required, not provided (§3.2).</summary>
    public sealed record FuncDecl(
        Token Name, List<Param> Params, TypeRef? ReturnType, List<Stmt>? Body,
        bool IsStatic = false, List<Attr>? Attributes = null,

        /// <summary>Declared with the <c>override</c> keyword — a claim that this replaces
        /// an inherited implementation, checked in both directions (§3.2).</summary>
        bool IsOverride = false) : Stmt;
    public sealed record Return(Token Keyword, Expr? Value) : Stmt;

    /// <summary>
    /// Leaving a loop early, and skipping to its next turn. Both carry their keyword
    /// token only — there is no labeled form, so there is nothing else to record.
    /// </summary>
    public sealed record Break(Token Keyword) : Stmt;
    public sealed record Continue(Token Keyword) : Stmt;

    public sealed record Throw(Token Keyword, Expr Value) : Stmt;

    /// <summary>
    /// <c>assert total == 10</c>. A statement rather than a call, so it needs no
    /// parentheses — the same shape as <c>throw</c>, and what §3.5 already wrote.
    ///
    /// It is the one construct that reads its own argument as <em>source</em> rather than
    /// as a value: a function receives <c>false</c> and can say nothing else, which is why
    /// §3.8 filed this as the only real macro demand.
    /// </summary>
    public sealed record Assert(Token Keyword, Expr Condition) : Stmt;

    /// <summary>
    /// <c>try { } catch e { }</c>. The catch name is bound to an Error inside the handler.
    /// Untyped in v0 — catching by type needs user-declared error classes first.
    /// </summary>
    public sealed record TryCatch(
        Token Keyword, List<Stmt> Body, Token CaughtName, List<Stmt> Handler) : Stmt;

    /// <summary>
    /// A class. <c>Members</c> holds VarDecls (fields), FuncDecls (methods), and at most
    /// one Constructor. The block-free file form (§3.3) produces the same node — only the
    /// parsing differs, so nothing downstream needs to know which shape was written.
    /// </summary>
    /// <summary>
    /// <c>Initializer</c> holds a module file's top-level statements — the code that is not
    /// a declaration. §3.3 lowers them to a static constructor, run once on first member
    /// access. They used to be handed through as "members", where every pass that walked
    /// members ignored anything that was not a declaration, and they ran nowhere at all.
    /// </summary>
    public sealed record ClassDecl(
        TypeKind Kind, Token Name, Token? BaseName,
        List<Token> Traits, List<Stmt> Members,
        List<Attr>? Attributes = null, List<Stmt>? Initializer = null,

        /// <summary>A file that declared no type, wrapped into one by <see cref="Project"/>.
        /// It reads like a class everywhere else, but its members see each other by their
        /// bare names — a file's own contents were the one thing it could not (§3.3).</summary>
        bool IsModule = false) : Stmt;

    public sealed record ConstructorDecl(
        Token Keyword, List<Param> Params, List<Stmt> Body) : Stmt;

    /// <summary>
    /// <c>enum Color { RED, GREEN, BLUE }</c> — a closed set of named values, and
    /// nothing else. No payloads: §6 harvested the demand as alignment, dock, orientation
    /// and color, all of which are plain names, and a tagged union is a different feature
    /// wearing the same keyword.
    /// </summary>
    public sealed record EnumDecl(
        Token Name, List<Token> Members, List<Attr>? Attributes = null,

        /// <summary>Methods written after the values. Payloads are still out — a tagged
        /// union is a different feature — but a fact about a value belongs on it (§3.2).</summary>
        List<Stmt>? Methods = null) : Stmt;
}

/// <summary>
/// Class, trait, and struct share one node — they differ in what they may contain and
/// how they are used, not in how they are written or parsed.
/// </summary>
public enum TypeKind { Class, Trait, Struct, Enum }
