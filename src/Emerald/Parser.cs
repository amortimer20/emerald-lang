using System.Text;

namespace Emerald;

/// <summary>
/// Tokens -> tree. A recursive-descent parser implementing §9 of the design doc.
/// Each method corresponds to one grammar production, in the same order.
/// </summary>
public sealed class Parser(
    List<Token> tokens, string fileName, Dictionary<int, string>? docs = null)
{
    private int _current;

    /// <summary>
    /// The <c>##</c> block ending on the line above <paramref name="line"/>, joined with
    /// newlines, or null if there is none.
    ///
    /// Walked upward from the declaration rather than collected downward from the comment,
    /// because that is the rule a reader already believes: a doc comment documents the
    /// thing under it, and a blank line between them breaks the connection.
    /// </summary>
    private string? DocAbove(int line)
    {
        if (docs is null) return null;

        List<string> block = [];
        for (int at = line - 1; docs.TryGetValue(at, out var text); at--) block.Insert(0, text);

        return block.Count == 0 ? null : string.Join("\n", block);
    }

    /// <summary>
    /// True while parsing an if/while condition or a for iterable. In those positions a
    /// bare <c>{</c> opens the statement's block, so it must not be read as a trailing
    /// lambda (§3.1). Kotlin resolves the same ambiguity the same way.
    /// </summary>
    private bool _noTrailingLambda;

    public List<Diagnostic> Diagnostics { get; } = [];

    public List<Stmt> ParseProgram()
    {
        List<Stmt> statements = [];
        SkipNewlines();
        while (!AtEnd)
        {
            var stmt = Statement();
            if (stmt is not null) statements.Add(stmt);
            SkipNewlines();
        }
        return statements;
    }

    // ---- statements -----------------------------------------------------

    private Stmt? Statement()
    {
        try
        {
            // Attributes are collected here rather than inside each declaration form,
            // because class members are parsed through this same method — so one place
            // covers members, top-level statements, and block-free class bodies alike.
            var attributes = Attributes();
            var stmt = Declaration();
            return attributes.Count == 0 ? stmt : Decorate(attributes, stmt);
        }
        catch (ParseError)
        {
            Synchronise();
            return null;
        }
    }

    private Stmt Declaration()
    {
        if (Check(TokenType.Class, TokenType.Trait, TokenType.Struct))
            return TypeDeclaration();
        if (Check(TokenType.Enum)) return EnumDeclaration();
        if (Check(TokenType.Constructor)) return ConstructorDeclaration();
        if (Check(TokenType.Static)) return StaticMember();
        if (Check(TokenType.Func, TokenType.Abstract, TokenType.Override))
            return FunctionDeclaration();
        if (Check(TokenType.Try)) return TryStatement();
        if (Check(TokenType.While)) return WhileStatement();
        if (Check(TokenType.Unless)) return UnlessStatement();
        if (Check(TokenType.For)) return ForStatement();
        if (Check(TokenType.If)) return IfStatementOrExpression();
        return Modifiable(SimpleStatement());
    }

    /// <summary>
    /// <c>@export</c> and <c>@name("Any")</c>, stacked one per line before the thing they
    /// describe. The vocabulary is fixed and compiler-known (§3.8), so which names are
    /// legal is the checker's business — this only reads the shape.
    /// </summary>
    private List<Attr> Attributes()
    {
        List<Attr> found = [];

        while (Match(TokenType.At))
        {
            var name = Consume(TokenType.Identifier, "Expected an attribute name after '@'.");

            Expr? argument = null;
            if (Match(TokenType.LeftParen))
            {
                argument = Expression();
                Consume(TokenType.RightParen, $"Expected ')' after @{name.Lexeme}'s argument.");
            }

            found.Add(new Attr(name, argument));
            SkipNewlines();
        }

        return found;
    }

    /// <summary>
    /// An attribute describes a declaration. Anything else — a loop, a call, an
    /// assignment — has no metadata to carry, so attaching one is a mistake worth naming
    /// rather than quietly dropping.
    /// </summary>
    private Stmt Decorate(List<Attr> attributes, Stmt stmt) => stmt switch
    {
        Stmt.VarDecl v => v with { Attributes = attributes },
        Stmt.FuncDecl f => f with { Attributes = attributes },
        Stmt.ClassDecl c => c with { Attributes = attributes },
        Stmt.EnumDecl e => e with { Attributes = attributes },
        _ => throw Error(attributes[0].Name,
                         $"@{attributes[0].Name.Lexeme} has nothing to describe here.",
                         "An attribute goes before a var, a func, or a type declaration."),
    };

    /// <summary>
    /// Wraps a simple statement in its modifier-<c>if</c>, if one follows. No same-line
    /// check is needed: a newline is a token, so if <c>if</c> is adjacent it was on the
    /// same line by construction.
    /// </summary>
    private Stmt Modifiable(Stmt stmt)
    {
        // Modifiers guard; they do not iterate. Ruby's `x += 1 while done` makes a
        // trailing modifier loop, which reads nothing like the control flow it is.
        if (Check(TokenType.While))
        {
            var loop = Peek;
            Error(loop, "while cannot be used as a modifier.",
                  "Write it as a loop:  while condition { ... }");
            return stmt;
        }

        if (Check(TokenType.Unless))
        {
            var keyword = Advance();
            return new Stmt.If(Negate(Condition(), keyword), [stmt], null);
        }

        if (!Match(TokenType.If)) return stmt;
        return new Stmt.If(Condition(), [stmt], null);
    }

    private Stmt SimpleStatement()
    {
        if (Match(TokenType.Var)) return VariableDeclaration(isConst: false);
        if (Match(TokenType.Const)) return VariableDeclaration(isConst: true);
        if (Check(TokenType.Return)) return ReturnStatement();
        if (Check(TokenType.Throw)) return ThrowStatement();
        if (Check(TokenType.Assert)) return new Stmt.Assert(Advance(), Expression());

        // Simple statements, so they pick up the guard modifier for free and
        // `break if found` reads the way `return x unless ok` already does.
        if (Check(TokenType.Break)) return new Stmt.Break(Advance());
        if (Check(TokenType.Continue)) return new Stmt.Continue(Advance());

        var expr = Expression();

        if (Check(TokenType.Assign, TokenType.PlusAssign, TokenType.MinusAssign,
                  TokenType.StarAssign, TokenType.SlashAssign))
        {
            var op = Advance();
            var value = Expression();
            return new Stmt.Assign(expr, op, value);
        }

        return new Stmt.ExprStmt(expr);
    }

    private Stmt VariableDeclaration(bool isConst, bool isStatic = false)
    {
        // var (name, score) = best. Unambiguous the moment a '(' follows var, since a
        // name can never start with one -- no lookahead beyond the token in hand.
        if (Check(TokenType.LeftParen))
        {
            if (isStatic)
                Error(Previous, "A static cannot be taken apart into two names.",
                      "Declare the pair, then read its halves where they are used.");

            Advance();
            var firstName = Consume(TokenType.Identifier, "Expected a name after '('.");
            Consume(TokenType.Comma, "Expected ',' between the two names.");
            var secondName = Consume(TokenType.Identifier, "Expected a second name.");
            Consume(TokenType.RightParen, "Expected ')' after the two names.");
            Consume(TokenType.Assign, "A destructure must be given a pair to take apart.");

            return new Stmt.PairDecl(firstName, secondName, Expression(), isConst);
        }

        var name = Consume(TokenType.Identifier, "Expected a name after 'var'.");
        TypeRef? type = Match(TokenType.Colon) ? ParseTypeRef() : null;

        // A property is a var with a body (§3.2) — no separate declaration form, so
        // promoting a field to a computed one never changes how callers write it.
        if (Check(TokenType.LeftBrace)) return PropertyDeclaration(name, type, isStatic);

        Expr? init = Match(TokenType.Assign) ? Expression() : null;

        if (isConst && init is null)
            Error(Previous, "A const must be given a value.");

        return new Stmt.VarDecl(name, type, init, isConst, isStatic);
    }

    private Stmt PropertyDeclaration(Token name, TypeRef? type, bool isStatic)
    {
        Consume(TokenType.LeftBrace, "Expected '{' to open the property body.");
        SkipNewlines();

        List<Stmt>? getter = null;
        List<Stmt>? setter = null;

        while (!Check(TokenType.RightBrace) && !AtEnd)
        {
            var word = Consume(TokenType.Identifier, "Expected 'get' or 'set'.");
            if (word.Lexeme == "get") getter = Block();
            else if (word.Lexeme == "set") setter = Block();
            else Error(word, $"Expected 'get' or 'set', found '{word.Lexeme}'.");
            SkipNewlines();
        }

        Consume(TokenType.RightBrace, "This property body is never closed.");

        if (getter is null)
            Error(name, $"Property {name.Lexeme} needs a get.",
                  "A var with a body computes its value:  var area: Float { get { ... } }");

        return new Stmt.VarDecl(name, type, null, IsConst: false, isStatic, getter, setter);
    }

    private Stmt ReturnStatement()
    {
        var keyword = Advance();
        Expr? value = EndsStatement() || StartsGuardModifier() ? null : Expression();
        return new Stmt.Return(keyword, value);
    }

    /// <summary>
    /// Whether what follows a valueless <c>return</c> is its guard rather than its value.
    ///
    /// <c>unless</c> is never an expression, so it is always the guard. <c>if</c> is
    /// genuinely ambiguous — <c>return if ready? then 1 else 0</c> returns an
    /// if-expression, while <c>return if done?</c> returns nothing under a guard — and the
    /// two are told apart the same way §9 tells if-statements from if-expressions: by
    /// whether a <c>then</c> turns up before the line ends.
    /// </summary>
    private bool StartsGuardModifier()
    {
        if (Check(TokenType.Unless)) return true;
        if (!Check(TokenType.If)) return false;

        for (int i = _current + 1; i < tokens.Count; i++)
        {
            if (tokens[i].Type == TokenType.Then) return false;
            if (tokens[i].Type is TokenType.Newline or TokenType.Eof or TokenType.RightBrace)
                return true;
        }

        return true;
    }

    /// <summary>
    /// <c>enum Color { RED, GREEN, BLUE }</c>.
    ///
    /// Comma-separated rather than newline-separated, because the body is a list of names
    /// and not a sequence of statements — the same shape as <c>with A, B</c> and
    /// <c>f(x, y)</c>. One rule that reads on one line or many, since newlines around the
    /// commas are skipped.
    /// </summary>
    private Stmt EnumDeclaration()
    {
        Advance();
        var name = Consume(TokenType.Identifier, "Expected a name after 'enum'.");

        Consume(TokenType.LeftBrace, $"Expected '{{' to open {name.Lexeme}'s body.");
        SkipNewlines();

        List<Token> members = [];
        if (!Check(TokenType.RightBrace) && !StartsAMember())
        {
            do
            {
                SkipNewlines();
                members.Add(Consume(TokenType.Identifier, "Expected a name for an enum value."));
                SkipNewlines();
            }
            while (Match(TokenType.Comma));
        }

        // The values first, then anything a body can hold. What an enum may actually keep
        // there is the checker's business; the shape is read here.
        SkipNewlines();
        List<Stmt> methods = [];
        while (!Check(TokenType.RightBrace) && !AtEnd)
        {
            var member = Statement();
            if (member is not null) methods.Add(member);
            SkipNewlines();
        }

        Consume(TokenType.RightBrace, $"This {name.Lexeme} body is never closed.");
        return new Stmt.EnumDecl(name, members, Methods: methods);
    }

    /// <summary>Whether what follows begins a member rather than another enum value.</summary>
    private bool StartsAMember() =>
        Check(TokenType.Func, TokenType.Static, TokenType.At, TokenType.Var,
              TokenType.Const, TokenType.Abstract, TokenType.Override);

    /// <summary>
    /// <c>class Dog extends Animal with Swimmer</c>, followed by either a braced body or —
    /// at file level — the rest of the file (§3.3). Both produce the same node.
    /// </summary>
    private Stmt TypeDeclaration()
    {
        var keyword = Advance();
        TypeKind kind = keyword.Type switch
        {
            TokenType.Trait => TypeKind.Trait,
            TokenType.Struct => TypeKind.Struct,
            _ => TypeKind.Class,
        };

        var name = Consume(TokenType.Identifier,
                           $"Expected a name after '{keyword.Lexeme}'.");

        Token? baseName = Match(TokenType.Extends)
            ? Consume(TokenType.Identifier, "Expected a base class name after 'extends'.")
            : null;

        List<Token> traits = [];
        if (Match(TokenType.With))
        {
            do traits.Add(Consume(TokenType.Identifier, "Expected a trait name after 'with'."));
            while (Match(TokenType.Comma));
        }

        List<Stmt> members = [];

        if (Check(TokenType.LeftBrace))
        {
            Advance();
            SkipNewlines();
            while (!Check(TokenType.RightBrace) && !AtEnd)
            {
                var member = Statement();
                if (member is not null) members.Add(member);
                SkipNewlines();
            }
            Consume(TokenType.RightBrace, $"This {keyword.Lexeme} body is never closed.");
        }
        else
        {
            // Block-free: everything to end of file is the body. A nested `class X { }`
            // below is therefore a nested type, not a sibling (§3.3).
            SkipNewlines();
            while (!AtEnd)
            {
                var member = Statement();
                if (member is not null) members.Add(member);
                SkipNewlines();
            }
        }

        return new Stmt.ClassDecl(kind, name, baseName, traits, members);
    }

    /// <summary>
    /// <c>static</c> binds to the type rather than an instance. A file without a class
    /// line is a module, which has no instances, so the keyword is disallowed there (§3.2)
    /// — that check belongs to the checker, which knows the surrounding context.
    /// </summary>
    private Stmt StaticMember()
    {
        Advance();  // static

        if (Match(TokenType.Var)) return VariableDeclaration(isConst: false, isStatic: true);
        if (Match(TokenType.Const)) return VariableDeclaration(isConst: true, isStatic: true);
        if (Check(TokenType.Func)) return FunctionDeclaration(isStatic: true);

        throw Error(Peek, "Expected var, const, or func after 'static'.");
    }

    private Stmt ConstructorDeclaration()
    {
        var keyword = Advance();
        var parameters = ParameterList();
        return new Stmt.ConstructorDecl(keyword, parameters, Block());
    }

    private Stmt FunctionDeclaration(bool isStatic = false)
    {
        // Read before any modifier is consumed, so the block above `abstract func` and the
        // block above a plain `func` are found the same way.
        string? doc = DocAbove(Peek.Line);

        bool isAbstract = Match(TokenType.Abstract);

        // A modifier, beside abstract and static rather than an attribute: §3.8 reserves
        // attributes for what generates no code and changes no checking, and this decides
        // whether the program compiles.
        bool isOverride = Match(TokenType.Override);

        Consume(TokenType.Func, "Expected 'func'.");
        var name = Consume(TokenType.Identifier, "Expected a function name after 'func'.");
        var parameters = ParameterList();
        TypeRef? returnType = Match(TokenType.Colon) ? ParseTypeRef() : null;

        // An abstract member states a requirement and stops. A null body carries that
        // downstream without a separate flag to keep in sync.
        return new Stmt.FuncDecl(name, parameters, returnType,
                                 isAbstract ? null : Block(), isStatic,
                                 IsOverride: isOverride, Doc: doc);
    }

    private Stmt ThrowStatement()
    {
        var keyword = Advance();
        return new Stmt.Throw(keyword, Expression());
    }

    /// <summary>
    /// <c>try { } catch e { }</c>. The catch clause is required — a <c>try</c> that
    /// swallows nothing does nothing, and one that swallows everything silently is worse.
    /// Stroustrup style puts <c>catch</c> on its own line, like <c>else</c>.
    /// </summary>
    private Stmt TryStatement()
    {
        var keyword = Advance();
        var body = Block();

        if (!Match(TokenType.Catch))
            throw Error(Peek, "A try needs a catch.",
                        "Say what to do when it fails:  catch error { ... }");

        var name = Consume(TokenType.Identifier, "Expected a name for the caught error.",
                           "The error is bound to it inside the handler:  catch error { ... }");

        return new Stmt.TryCatch(keyword, body, name, Block());
    }

    private Stmt WhileStatement()
    {
        Advance();
        return new Stmt.While(Condition(), Block());
    }

    /// <summary>
    /// <c>unless</c> is <c>if not</c>. It deliberately takes no <c>else</c>: Ruby permits
    /// one, and "unless x … else …" is a double negative that every style guide bans.
    /// </summary>
    private Stmt UnlessStatement()
    {
        var keyword = Advance();
        var condition = Condition();
        var body = Block();

        if (Check(TokenType.Else))
            Error(Peek, "unless cannot have an else.",
                  "\"unless x ... else ...\" reads as a double negative. "
                  + "Use if with the condition the other way round.");

        return new Stmt.If(Negate(condition, keyword), body, null);
    }

    /// <summary>
    /// Wraps a condition in <c>not</c>, keeping the keyword's line so a diagnostic points
    /// at what was written rather than at machinery the user never typed.
    /// </summary>
    private Expr Negate(Expr condition, Token keyword)
    {
        if (condition is Expr.Unary { Op.Type: TokenType.Not })
            Error(keyword, $"{keyword.Lexeme} with not is a double negative.",
                  $"Drop the not, or use {(keyword.Type == TokenType.Unless ? "if" : "while")} instead.");

        return new Expr.Unary(
            new Token(TokenType.Not, "not", null, keyword.Line), condition);
    }

    private Stmt ForStatement()
    {
        Advance();

        // for (key, value) in pairs -- the same shape as the var form, so learning one
        // teaches the other.
        Token? second = null;
        Token variable;

        if (Match(TokenType.LeftParen))
        {
            variable = Consume(TokenType.Identifier, "Expected a name after '('.");
            Consume(TokenType.Comma, "Expected ',' between the two loop variables.");
            second = Consume(TokenType.Identifier, "Expected a second loop variable.");
            Consume(TokenType.RightParen, "Expected ')' after the two loop variables.");
        }
        else variable = Consume(TokenType.Identifier,
                                "Expected a loop variable after 'for'.");

        Consume(TokenType.In, "Expected 'in' after the loop variable.");
        var iterable = Condition();
        return new Stmt.For(variable, iterable, Block(), second);
    }

    /// <summary>
    /// The three-if disambiguation (§9.1): parse the condition, then peek. A <c>{</c>
    /// means this is the statement form; <c>then</c> means an if-expression was used as
    /// an expression statement. One token of lookahead past the condition, no more.
    /// </summary>
    private Stmt IfStatementOrExpression()
    {
        Advance();  // if
        var condition = Condition();

        if (Check(TokenType.Then))
        {
            Advance();
            var thenValue = Expression();
            Consume(TokenType.Else, "An if/then expression needs an else.",
                    "Every branch must produce a value. For a conditional statement, "
                    + "use the block form: if cond { ... }");
            var elseValue = Expression();
            return new Stmt.ExprStmt(new Expr.IfExpr(condition, thenValue, elseValue));
        }

        var thenBranch = Block();
        List<Stmt>? elseBranch = null;

        if (Match(TokenType.Else))
            elseBranch = Check(TokenType.If) ? [IfStatementOrExpression()] : Block();

        return new Stmt.If(condition, thenBranch, elseBranch);
    }

    private Expr Condition()
    {
        _noTrailingLambda = true;
        try { return Expression(); }
        finally { _noTrailingLambda = false; }
    }

    private List<Stmt> Block()
    {
        // Reaching a block with '=' next means the condition was an assignment, which
        // the grammar forbids (§3.1). Say what actually went wrong rather than reporting
        // a missing brace, which is true and useless.
        if (Check(TokenType.Assign))
            throw Error(Peek, "Assignment cannot appear in a condition.",
                        "Emerald uses = to assign a value and == to compare two values. "
                        + "Did you mean ==?",
                        topic: "assign-in-condition");

        Consume(TokenType.LeftBrace, "Expected '{' to open a block.");
        List<Stmt> statements = [];
        SkipNewlines();
        while (!Check(TokenType.RightBrace) && !AtEnd)
        {
            var stmt = Statement();
            if (stmt is not null) statements.Add(stmt);
            SkipNewlines();
        }
        Consume(TokenType.RightBrace, "This block is never closed.");
        return statements;
    }

    // ---- expressions ----------------------------------------------------

    private Expr Expression()
    {
        if (Check(TokenType.If)) return IfExpression();
        return Or();
    }

    private Expr IfExpression()
    {
        Advance();
        var condition = Expression();
        Consume(TokenType.Then, "Expected 'then' in an if expression.");
        var thenValue = Expression();
        Consume(TokenType.Else, "An if/then expression needs an else.",
                "Every branch must produce a value.");
        return new Expr.IfExpr(condition, thenValue, Expression());
    }

    private Expr Or()
    {
        var expr = And();
        while (Match(TokenType.Or)) expr = new Expr.Logical(expr, Previous, And());
        return expr;
    }

    private Expr And()
    {
        var expr = NotExpr();
        while (Match(TokenType.And)) expr = new Expr.Logical(expr, Previous, NotExpr());
        return expr;
    }

    private Expr NotExpr() =>
        Match(TokenType.Not) ? new Expr.Unary(Previous, NotExpr()) : Comparison();

    private Expr Comparison()
    {
        var expr = RangeExpression();

        // `is` sits with the comparisons because it answers one: it takes a type on the
        // right rather than an expression, which is why it is its own node and not a
        // Binary with a name in it.
        // `as` binds tighter than the comparisons, because its answer is a value and
        // `pet as Dog == nothing` is the obvious thing to write. `is` below does not, and
        // does not need to: its answer is already a Bool, so there is nothing to compare
        // it against that is not a longer way of saying it. C# splits them the same way.
        if (Match(TokenType.As))
            expr = new Expr.TypeCast(expr, Previous, ParseTypeRef());

        if (Match(TokenType.Is))
        {
            var keyword = Previous;
            return new Expr.TypeTest(expr, keyword, ParseTypeRef());
        }

        if (Check(TokenType.Equal, TokenType.NotEqual, TokenType.Less,
                  TokenType.Greater, TokenType.LessEqual, TokenType.GreaterEqual))
        {
            var op = Advance();
            expr = new Expr.Binary(expr, op, RangeExpression());
        }
        return expr;
    }

    private Expr RangeExpression()
    {
        var expr = Additive();
        if (Match(TokenType.DotDot)) expr = new Expr.RangeExpr(expr, Additive());
        return expr;
    }

    private Expr Additive()
    {
        var expr = Multiplicative();
        while (Check(TokenType.Plus, TokenType.Minus))
            expr = new Expr.Binary(expr, Advance(), Multiplicative());
        return expr;
    }

    private Expr Multiplicative()
    {
        var expr = Unary();
        while (Check(TokenType.Star, TokenType.Slash, TokenType.SlashSlash, TokenType.Percent))
            expr = new Expr.Binary(expr, Advance(), Unary());
        return expr;
    }

    private Expr Unary() =>
        Match(TokenType.Minus) ? new Expr.Unary(Previous, Unary()) : Power();

    /// <summary>
    /// <c>**</c> binds tighter than unary minus and is right-associative, matching Python
    /// and Ruby. So <c>-2 ** 2</c> is <c>-(2 ** 2)</c> = -4, and <c>2 ** 3 ** 2</c> is
    /// <c>2 ** 9</c>. Parsing the right side as a full unary is what allows <c>2 ** -1</c>.
    /// </summary>
    private Expr Power()
    {
        var left = Postfix();
        return Match(TokenType.StarStar)
            ? new Expr.Binary(left, Previous, Unary())
            : left;
    }

    private Expr Postfix()
    {
        var expr = Primary();
        while (true)
        {
            if (Match(TokenType.Dot, TokenType.QuestionDot))
            {
                bool optional = Previous.Type == TokenType.QuestionDot;
                expr = new Expr.Get(expr, MemberName(), optional);
                expr = MaybeCall(expr);
            }
            else if (Match(TokenType.LeftBracket))
            {
                var bracket = Previous;
                bool saved = _noTrailingLambda;
                _noTrailingLambda = false;      // brackets delimit, so a lambda is safe here
                var position = Expression();
                _noTrailingLambda = saved;
                Consume(TokenType.RightBracket, "Expected ']' to close the index.");
                expr = new Expr.Index(expr, bracket, position);
            }
            else if (Check(TokenType.LeftParen) || CanTakeTrailingLambda())
            {
                expr = MaybeCall(expr);
            }

            // A '<' might open type arguments and might be a comparison. MaybeCall hands
            // the callee straight back when it turns out to be the latter, and consumes
            // nothing -- so this must stop rather than ask again, or `a < b` spins here
            // forever. Found by writing one.
            else if (Check(TokenType.Less))
            {
                var called = MaybeCall(expr);
                if (ReferenceEquals(called, expr)) break;
                expr = called;
            }
            else break;
        }
        return expr;
    }

    /// <summary>
    /// A member name after '.'. Keywords are allowed here — the position is unambiguous,
    /// and without this <c>.or(0)</c> collides with the <c>or</c> operator. Member names
    /// live in their own namespace, which is why <c>list.count</c> stays legal even if
    /// <c>count</c> later becomes a keyword.
    /// </summary>
    private Token MemberName()
    {
        if (Check(TokenType.Identifier)) return Advance();

        if (Peek.Type is not (TokenType.Newline or TokenType.Eof)
            && char.IsAsciiLetter(Peek.Lexeme.FirstOrDefault()))
            return Advance() with { Type = TokenType.Identifier };

        throw Error(Peek, "Expected a name after '.'.");
    }

    /// <summary>Attaches an argument list and/or a trailing lambda, if present.</summary>
    private Expr MaybeCall(Expr callee)
    {
        List<Expr> args = [];
        bool called = false;
        var typeArgs = TypeArguments();

        if (Match(TokenType.LeftParen))
        {
            called = true;
            SkipNewlines();
            if (!Check(TokenType.RightParen))
            {
                do { SkipNewlines(); args.Add(Expression()); SkipNewlines(); }
                while (Match(TokenType.Comma));
            }
            Consume(TokenType.RightParen, "Expected ')' to close the arguments.");
        }

        Expr.Lambda? trailing = null;
        if (CanTakeTrailingLambda())
        {
            trailing = LambdaLiteral();
            called = true;
        }

        return called ? new Expr.Call(callee, args, trailing, typeArgs) : callee;
    }

    /// <summary>
    /// The <c>&lt;Dog&gt;</c> of <c>animal.as&lt;Dog&gt;()</c>, or null when the <c>&lt;</c>
    /// in hand is a comparison after all.
    ///
    /// The classic ambiguity — <c>a&lt;b&gt;(c)</c> is a generic call in C# and a pair of
    /// comparisons in most languages — is nearly absent here, because §3.1 allows only one
    /// comparison operator in a row: <c>a &lt; b &gt; c</c> is already an error, so no
    /// valid program can mean the other thing. The rewind is kept anyway, for the cases
    /// that are not calls at all: <c>a &lt; b</c> followed by a newline reaches here too,
    /// and must be handed back untouched.
    ///
    /// The closing <c>&gt;</c> must be followed immediately by <c>(</c>. Type arguments
    /// with no call after them are not a form this language has.
    /// </summary>
    private List<TypeRef>? TypeArguments()
    {
        if (!Check(TokenType.Less)) return null;

        int mark = _current;
        int reported = Diagnostics.Count;

        try
        {
            Advance();
            List<TypeRef> args = [];
            do { args.Add(ParseTypeRef()); } while (Match(TokenType.Comma));

            if (Match(TokenType.Greater) && Check(TokenType.LeftParen)) return args;
        }
        catch (ParseError)
        {
            // Not type arguments. The rewind below puts it back and the comparison path
            // reports whatever is really wrong, on the token the reader wrote.
        }

        _current = mark;
        if (Diagnostics.Count > reported)
            Diagnostics.RemoveRange(reported, Diagnostics.Count - reported);

        return null;
    }

    private bool CanTakeTrailingLambda() =>
        !_noTrailingLambda && Check(TokenType.LeftBrace);

    private Expr.Lambda LambdaLiteral()
    {
        Consume(TokenType.LeftBrace, "Expected '{' to open a lambda.");
        List<Param> parameters = [];

        // { x => ... } and { x, y => ... }; a bare { ... } takes no parameters.
        int save = _current;
        if (Check(TokenType.Identifier))
        {
            List<Param> candidate = [];
            bool ok = true;
            do
            {
                if (!Check(TokenType.Identifier)) { ok = false; break; }
                candidate.Add(new Param(Advance(), null, null));
            }
            while (Match(TokenType.Comma));

            if (ok && Match(TokenType.Arrow)) parameters = candidate;
            else _current = save;
        }

        // A lambda body is parsed with the outer no-lambda restriction lifted.
        bool saved = _noTrailingLambda;
        _noTrailingLambda = false;

        List<Stmt> body = [];
        SkipNewlines();
        while (!Check(TokenType.RightBrace) && !AtEnd)
        {
            var stmt = Statement();
            if (stmt is not null) body.Add(stmt);
            SkipNewlines();
        }
        Consume(TokenType.RightBrace, "This lambda is never closed.");

        _noTrailingLambda = saved;
        return new Expr.Lambda(parameters, body);
    }

    private Expr Primary()
    {
        if (Match(TokenType.True)) return new Expr.Literal(true, Previous.Line);
        if (Match(TokenType.False)) return new Expr.Literal(false, Previous.Line);
        if (Match(TokenType.Nothing)) return new Expr.Literal(null, Previous.Line);
        if (Check(TokenType.Int, TokenType.Float)) { var number = Advance(); return new Expr.Literal(number.Literal, number.Line); }
        if (Check(TokenType.String)) return StringExpression(Advance());
        if (Check(TokenType.LeftBrace)) return LambdaLiteral();

        if (Match(TokenType.LeftBracket))
        {
            var bracket = Previous;
            bool saved = _noTrailingLambda;
            _noTrailingLambda = false;
            SkipNewlines();

            // [:] is the empty dictionary. [] is the empty list — the two need telling
            // apart, and a bare [] has no key to reveal which was meant.
            if (Match(TokenType.Colon))
            {
                _noTrailingLambda = saved;
                Consume(TokenType.RightBracket, "Expected ']' after '[:'.");
                return new Expr.DictLiteral(bracket, []);
            }

            List<Expr> items = [];
            List<Entry> entries = [];

            if (!Check(TokenType.RightBracket))
            {
                do
                {
                    SkipNewlines();
                    var first = Expression();

                    // The colon after the first element decides which literal this is,
                    // and every element after it must agree.
                    if (entries.Count > 0 || (items.Count == 0 && Check(TokenType.Colon)))
                    {
                        Consume(TokenType.Colon,
                                "Expected ':' — this literal started as a dictionary.");
                        SkipNewlines();
                        entries.Add(new Entry(first, Expression()));
                    }
                    else
                    {
                        if (Check(TokenType.Colon))
                            throw Error(Peek, "Expected ',' — this literal started as a list.",
                                        "A literal is a list or a dictionary, not both. "
                                        + "Write every item as key: value, or none of them.");
                        items.Add(first);
                    }

                    SkipNewlines();
                }
                while (Match(TokenType.Comma));
            }

            _noTrailingLambda = saved;
            Consume(TokenType.RightBracket,
                    entries.Count > 0
                        ? "Expected ']' to close the dictionary."
                        : "Expected ']' to close the list.");

            return entries.Count > 0
                ? new Expr.DictLiteral(bracket, entries)
                : new Expr.ListLiteral(bracket, items);
        }

        if (Check(TokenType.Identifier))
        {
            // A bare arrow lambda: x => expr
            if (PeekAt(1).Type == TokenType.Arrow)
            {
                var param = Advance();
                Advance();  // =>
                var value = Expression();
                return new Expr.Lambda([new Param(param, null, null)],
                                       [new Stmt.ExprStmt(value)]);
            }
            return new Expr.Variable(Advance());
        }

        if (Match(TokenType.LeftParen))
        {
            SkipNewlines();
            bool saved = _noTrailingLambda;
            _noTrailingLambda = false;      // parens lift the condition restriction
            var inner = Expression();
            _noTrailingLambda = saved;
            SkipNewlines();
            Consume(TokenType.RightParen, "Expected ')' to close the group.");
            return new Expr.Grouping(inner);
        }

        throw Error(Peek, $"Expected a value, found {Describe(Peek)}.");
    }

    // ---- string interpolation -------------------------------------------

    /// <summary>
    /// Splits "a #{b} c" into literal and expression parts, running a nested scanner and
    /// parser over each #{...}. Done here rather than in the scanner because the contents
    /// are full expressions.
    /// </summary>
    private Expr StringExpression(Token token)
    {
        string raw = (string)token.Literal!;
        if (!raw.Contains("#{") && !raw.Contains('\\')) return new Expr.Literal(raw, token.Line);

        List<Expr> parts = [];
        var literal = new StringBuilder();

        for (int i = 0; i < raw.Length; i++)
        {
            // The scanner leaves \# and \\ escaped so this loop can tell an interpolation
            // from a hash the programmer asked for. Undone here, where it has been read.
            if (raw[i] == '\\' && i + 1 < raw.Length && raw[i + 1] is '#' or '\\')
            {
                literal.Append(raw[i + 1]);
                i++;
                continue;
            }

            if (raw[i] == '#' && i + 1 < raw.Length && raw[i + 1] == '{')
            {
                if (literal.Length > 0)
                {
                    parts.Add(new Expr.Literal(literal.ToString(), token.Line));
                    literal.Clear();
                }

                int depth = 1;
                int start = i + 2;
                int j = start;
                while (j < raw.Length && depth > 0)
                {
                    // Skip nested strings, so a brace inside one does not count.
                    if (raw[j] == '"')
                    {
                        j++;
                        while (j < raw.Length && raw[j] != '"')
                            j += raw[j] == '\\' ? 2 : 1;
                    }
                    else if (raw[j] == '{') depth++;
                    else if (raw[j] == '}') depth--;

                    if (depth > 0) j++;
                }

                if (depth > 0)
                {
                    Error(token, "This #{ } is never closed.");
                    break;
                }

                // An empty hole used to reach the fragment parser, which reported
                // "Could not read ''" — true, and no help at all about what was wanted.
                if (raw[start..j].Trim().Length == 0)
                {
                    Error(token, "This #{ } has nothing in it.",
                          "Put a value between the braces:  \"hello #{name}\""
                          + "\n  For a literal one, escape the hash:  \\#{ }");
                    i = j;
                    continue;
                }

                parts.Add(ParseFragment(raw[start..j], token.Line));
                i = j;
            }
            else literal.Append(raw[i]);
        }

        if (literal.Length > 0) parts.Add(new Expr.Literal(literal.ToString(), token.Line));
        return new Expr.Interpolation(parts);
    }

    private Expr ParseFragment(string source, int line)
    {
        var scanner = new Scanner(source, fileName);

        // The fragment scanner counts from 1, so shift its lines onto the real file —
        // otherwise every diagnostic inside a #{ } points at line 1.
        var tokens = scanner.ScanTokens()
            .Select(t => t with { Line = line + t.Line - 1 })
            .ToList();

        var sub = new Parser(tokens, fileName);
        Diagnostics.AddRange(scanner.Diagnostics);

        try
        {
            var expr = sub.Expression();
            Diagnostics.AddRange(sub.Diagnostics);
            return expr;
        }
        catch (ParseError)
        {
            Diagnostics.Add(new Diagnostic(fileName, line, $"Could not read '{source}'."));
            return new Expr.Literal("");
        }
    }

    // ---- types ----------------------------------------------------------

    private TypeRef ParseTypeRef()
    {
        // func(Int): String — a function's type is its header without the name. Only the
        // parameter types appear: a name in there would describe nothing, since the caller
        // supplies a block whose parameters carry their own names.
        if (Check(TokenType.Func))
        {
            var keyword = Advance();
            Consume(TokenType.LeftParen, "Expected '(' after func in a type.");

            List<TypeRef> takes = [];
            if (!Check(TokenType.RightParen))
                do { takes.Add(ParseTypeRef()); } while (Match(TokenType.Comma));

            Consume(TokenType.RightParen, "Expected ')' to close the parameter types.");

            TypeRef? returns = Match(TokenType.Colon) ? ParseTypeRef() : null;

            return new TypeRef(keyword, Match(TokenType.Question), null,
                               new FuncRef(takes, returns));
        }

        var name = Consume(TokenType.Identifier, "Expected a type name.");

        // The scanner folds a trailing '?' into the identifier, because that is how
        // predicate method names work (§3.4). On a type it means nullable instead.
        if (name.Lexeme.EndsWith('?'))
            return new TypeRef(name with { Lexeme = name.Lexeme[..^1] }, Nullable: true);

        // List<String>. One type argument, because List is the only generic there is —
        // §5.3 makes the parameterised containers compiler-owned, so this grammar is for
        // consuming them, never for declaring one.
        //
        // Nesting works without special handling: List<List<Int>> closes with two
        // Greater tokens, since Emerald has no shift operators to confuse them with.
        List<TypeRef>? arguments = null;
        if (Match(TokenType.Less))
        {
            arguments = [];
            do { arguments.Add(ParseTypeRef()); } while (Match(TokenType.Comma));
            Consume(TokenType.Greater, $"Expected '>' to close {name.Lexeme}<...>.");
        }

        // A '?' after the closing '>' cannot have been folded into an identifier, so it
        // arrives as its own token: Array<Int>?
        bool nullable = Match(TokenType.Question);

        return new TypeRef(name, nullable, arguments);
    }

    private List<Param> ParameterList()
    {
        Consume(TokenType.LeftParen, "Expected '(' after the name.");
        List<Param> parameters = [];
        if (!Check(TokenType.RightParen))
        {
            do
            {
                var name = Consume(TokenType.Identifier, "Expected a parameter name.");
                TypeRef? type = Match(TokenType.Colon) ? ParseTypeRef() : null;
                Expr? def = Match(TokenType.Assign) ? Expression() : null;
                parameters.Add(new Param(name, type, def));
            }
            while (Match(TokenType.Comma));
        }
        Consume(TokenType.RightParen, "Expected ')' after the parameters.");
        return parameters;
    }

    // ---- plumbing -------------------------------------------------------

    private sealed class ParseError : Exception;

    private bool AtEnd => Peek.Type == TokenType.Eof;
    private Token Peek => tokens[_current];
    private Token Previous => tokens[_current - 1];
    private Token PeekAt(int offset) =>
        tokens[Math.Min(_current + offset, tokens.Count - 1)];

    private bool EndsStatement() =>
        Check(TokenType.Newline, TokenType.RightBrace, TokenType.Eof);

    private Token Advance() => tokens[_current++];

    private bool Check(params TokenType[] types) => types.Contains(Peek.Type);

    private bool Match(params TokenType[] types)
    {
        if (!Check(types)) return false;
        Advance();
        return true;
    }

    private void SkipNewlines()
    {
        while (Check(TokenType.Newline)) Advance();
    }

    private Token Consume(TokenType type, string message, string? hint = null)
    {
        if (Check(type)) return Advance();
        throw Error(Peek, message, hint);
    }

    private ParseError Error(Token token, string message, string? hint = null,
                             string? topic = null)
    {
        Diagnostics.Add(new Diagnostic(fileName, token.Line, message, hint, Topic: topic));
        return new ParseError();
    }

    /// <summary>
    /// After an error, skip to the next statement boundary so one mistake produces one
    /// message rather than a cascade (§3.6).
    /// </summary>
    private void Synchronise()
    {
        // Must always consume at least one token. Returning without progress means the
        // next attempt re-parses the same failing construct, fails identically, and the
        // compiler spins — which is far worse than a poor error message.
        int start = _current;

        while (!AtEnd)
        {
            // _current is 0 when the very first token of a file fails to parse, and there
            // is no previous token to inspect. Reading one crashed the compiler with a
            // .NET stack trace — the exact thing §3.6 exists to prevent — for any file
            // starting with something unparseable, `@export` among them.
            if (_current > 0 && Previous.Type == TokenType.Newline) break;
            if (Check(TokenType.Var, TokenType.Const, TokenType.Func, TokenType.If,
                      TokenType.While, TokenType.For, TokenType.Return, TokenType.Try)) break;
            Advance();
        }

        if (_current == start && !AtEnd) Advance();
    }

    private static string Describe(Token token) => token.Type switch
    {
        TokenType.Eof => "the end of the file",
        TokenType.Newline => "the end of the line",
        _ => $"'{token.Lexeme}'"
    };
}
