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
/// A written type. <c>Arguments</c> holds the type arguments of a generic —
/// <c>List&lt;T&gt;</c> takes one and <c>Dictionary&lt;K, V&gt;</c> two. §5.3 makes the
/// parameterised containers compiler-owned, so this grammar is for consuming them and
/// never for declaring one.
/// </summary>
public sealed record TypeRef(Token Name, bool Nullable, List<TypeRef>? Arguments = null);

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
    public sealed record Literal(object? Value) : Expr;

    /// <summary>"a #{b} c" — alternating literal and expression parts.</summary>
    public sealed record Interpolation(List<Expr> Parts) : Expr;

    public sealed record Variable(Token Name) : Expr;
    public sealed record Grouping(Expr Inner) : Expr;
    public sealed record Unary(Token Op, Expr Right) : Expr;
    public sealed record Binary(Expr Left, Token Op, Expr Right) : Expr;

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

    /// <summary>Property or method access: <c>dog.name</c>, <c>5.times</c>.</summary>
    public sealed record Get(Expr Target, Token Name) : Expr;

    /// <summary>
    /// A call. <c>Trailing</c> is the trailing-lambda sprinkle: <c>1.upto(5) { i => ... }</c>
    /// and <c>5.times { ... }</c> both land here.
    /// </summary>
    public sealed record Call(Expr Callee, List<Expr> Args, Lambda? Trailing) : Expr;
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
    public sealed record For(Token Variable, Expr Iterable, List<Stmt> Body) : Stmt;
    /// <summary>A null <c>Body</c> means abstract: required, not provided (§3.2).</summary>
    public sealed record FuncDecl(
        Token Name, List<Param> Params, TypeRef? ReturnType, List<Stmt>? Body,
        bool IsStatic = false, List<Attr>? Attributes = null) : Stmt;
    public sealed record Return(Token Keyword, Expr? Value) : Stmt;

    /// <summary>
    /// Leaving a loop early, and skipping to its next turn. Both carry their keyword
    /// token only — there is no labelled form, so there is nothing else to record.
    /// </summary>
    public sealed record Break(Token Keyword) : Stmt;
    public sealed record Continue(Token Keyword) : Stmt;

    public sealed record Throw(Token Keyword, Expr Value) : Stmt;

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
    public sealed record ClassDecl(
        TypeKind Kind, Token Name, Token? BaseName,
        List<Token> Traits, List<Stmt> Members,
        List<Attr>? Attributes = null) : Stmt;

    public sealed record ConstructorDecl(
        Token Keyword, List<Param> Params, List<Stmt> Body) : Stmt;
}

/// <summary>
/// Class, trait, and struct share one node — they differ in what they may contain and
/// how they are used, not in how they are written or parsed.
/// </summary>
public enum TypeKind { Class, Trait, Struct }
