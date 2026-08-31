namespace Emerald;

public sealed record Diagnostic(string File, int Line, string Message, string? Hint = null);

/// <summary>
/// A parsed type annotation. v0 records these and does nothing with them — the type
/// checker is a separate pass over this same tree, and it cannot be written until the
/// tree exists. Parsing them now means adding the checker later changes no syntax.
/// </summary>
public sealed record TypeRef(Token Name, bool Nullable);

public sealed record Param(Token Name, TypeRef? Type, Expr? Default);

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
    public sealed record ArrayLiteral(Token Bracket, List<Expr> Items) : Expr;

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
        List<Stmt>? Getter = null, List<Stmt>? Setter = null) : Stmt;

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
        bool IsStatic = false) : Stmt;
    public sealed record Return(Token Keyword, Expr? Value) : Stmt;

    /// <summary>
    /// A class. <c>Members</c> holds VarDecls (fields), FuncDecls (methods), and at most
    /// one Constructor. The block-free file form (§3.3) produces the same node — only the
    /// parsing differs, so nothing downstream needs to know which shape was written.
    /// </summary>
    public sealed record ClassDecl(
        TypeKind Kind, Token Name, Token? BaseName,
        List<Token> Traits, List<Stmt> Members) : Stmt;

    public sealed record ConstructorDecl(
        Token Keyword, List<Param> Params, List<Stmt> Body) : Stmt;
}

/// <summary>
/// Class, trait, and struct share one node — they differ in what they may contain and
/// how they are used, not in how they are written or parsed.
/// </summary>
public enum TypeKind { Class, Trait, Struct }
