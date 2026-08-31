using System.Text;

namespace Emerald;

/// <summary>
/// Tree -> behaviour. A tree-walking interpreter: each node type knows how to evaluate
/// itself, recursively. Slow by design and simple by design — the CIL backend replaces
/// this later, but the semantics get decided here.
/// </summary>
public sealed class Interpreter
{
    private readonly Env _globals = new();

    /// <summary>
    /// The line currently being evaluated — a program counter, updated wherever a node
    /// carries a token. Runtime errors read it on the way out so they can point at a
    /// line, which compile-time diagnostics get for free but runtime ones do not.
    /// </summary>
    private int _line;

    public Interpreter()
    {
        foreach (var (name, fn) in Builtins.Kernel)
            _globals.Declare(name, new NativeFunction(name, fn));

        foreach (var (name, module) in Builtins.Modules)
            _globals.Declare(name, module);
    }

    public void Run(List<Stmt> program)
    {
        try
        {
            // Functions are declared before anything runs, matching the checker, so a
            // file reads top to bottom without forward declarations and mutual recursion
            // works. Without this the checker accepts programs the runtime then rejects.
            foreach (var stmt in program)
                if (stmt is Stmt.FuncDecl fn)
                    _globals.Declare(fn.Name.Lexeme,
                                     new EmFunction(fn.Name.Lexeme, fn.Params, fn.Body, _globals));

            foreach (var stmt in program) Execute(stmt, _globals);
        }
        catch (RuntimeError error)
        {
            if (error.Line == 0) error.Line = _line;
            throw;
        }
    }

    // ---- statements -----------------------------------------------------

    private void Execute(Stmt stmt, Env env)
    {
        switch (stmt)
        {
            case Stmt.VarDecl v:
                _line = v.Name.Line;
                env.Declare(v.Name.Lexeme,
                            v.Init is null ? null : Evaluate(v.Init, env),
                            v.IsConst);
                break;

            case Stmt.Assign a:
                ExecuteAssign(a, env);
                break;

            case Stmt.ExprStmt e:
                ExecuteExpressionStatement(e, env);
                break;

            case Stmt.If i:
                if (Truthy(Evaluate(i.Condition, env)))
                    ExecuteBlock(i.Then, new Env(env));
                else if (i.Else is not null)
                    ExecuteBlock(i.Else, new Env(env));
                break;

            case Stmt.While w:
                while (Truthy(Evaluate(w.Condition, env)))
                    ExecuteBlock(w.Body, new Env(env));
                break;

            case Stmt.For f:
                ExecuteFor(f, env);
                break;

            case Stmt.FuncDecl fn:
                env.Declare(fn.Name.Lexeme, new EmFunction(fn.Name.Lexeme, fn.Params, fn.Body, env));
                break;

            case Stmt.ClassDecl c:
                env.Declare(c.Name.Lexeme, BuildClass(c, env));
                break;

            case Stmt.Return r:
                throw new ReturnSignal(r.Value is null ? null : Evaluate(r.Value, env));
        }
    }

    private void ExecuteAssign(Stmt.Assign a, Env env)
    {
        _line = a.Op.Line;

        // self.name = value — assigning to a field rather than a local.
        if (a.Target is Expr.Get field)
        {
            object? receiver = Evaluate(field.Target, env);

            // Circle.made += 1 — type-level state, one copy shared by every instance.
            if (receiver is EmClass cls)
            {
                var owner = cls.OwnerOfStatic(field.Name.Lexeme)
                    ?? throw new RuntimeError(
                        $"No class member named {field.Name.Lexeme} on {cls.Name}.");

                object? updated = Evaluate(a.Value, env);
                if (a.Op.Type != TokenType.Assign)
                    updated = Arithmetic(owner.Statics[field.Name.Lexeme],
                                         CompoundOp(a.Op.Type), updated, a.Op);

                owner.Statics[field.Name.Lexeme] = updated;
                return;
            }

            if (receiver is not EmInstance instance)
                throw new RuntimeError(
                    $"Cannot assign to a member of {Builtins.TypeName(receiver)}.");

            object? newValue = Evaluate(a.Value, env);
            if (a.Op.Type != TokenType.Assign)
            {
                instance.Fields.TryGetValue(field.Name.Lexeme, out object? current);
                newValue = Arithmetic(current, CompoundOp(a.Op.Type), newValue, a.Op);
            }
            SetField(instance, field.Name, newValue);
            return;
        }

        if (a.Target is not Expr.Variable target)
            throw new RuntimeError("Only a variable or a member can be assigned to.");

        object? value = Evaluate(a.Value, env);

        if (a.Op.Type != TokenType.Assign)
        {
            if (!env.TryGet(target.Name.Lexeme, out object? current))
                throw Unknown(target.Name);

            value = Arithmetic(current, CompoundOp(a.Op.Type), value, a.Op);
        }

        if (!env.TryAssign(target.Name.Lexeme, value)) throw Unknown(target.Name);
    }

    /// <summary>
    /// A bare function name used as a statement is a call — <c>exit</c> means
    /// <c>exit()</c>, the same way <c>s.upper</c> means <c>s.upper()</c> (§3.1). Only in
    /// statement position: there, naming a function and discarding it can never be what
    /// anyone meant, whereas in expression position a bare name may be a real value.
    /// A class name is left alone, so <c>Dog</c> does not silently construct one.
    /// </summary>
    private void ExecuteExpressionStatement(Stmt.ExprStmt statement, Env env)
    {
        object? value = Evaluate(statement.Expression, env);

        if (statement.Expression is Expr.Variable
            && value is ICallable callable and not EmClass)
        {
            callable.Call(this, []);
        }
    }

    private void ExecuteFor(Stmt.For f, Env env)
    {
        _line = f.Variable.Line;
        object? iterable = Evaluate(f.Iterable, env);
        if (iterable is not EmRange range)
            throw new RuntimeError(
                $"Cannot loop over {Builtins.TypeName(iterable)}.",
                "v0 can loop over a range, like: for i in 1..5 { ... }");

        foreach (long i in range)
        {
            var scope = new Env(env);
            scope.Declare(f.Variable.Lexeme, i);
            ExecuteBlock(f.Body, scope);
        }
    }

    private void ExecuteBlock(List<Stmt> body, Env env)
    {
        foreach (var stmt in body) Execute(stmt, env);
    }

    // ---- classes --------------------------------------------------------

    private EmClass BuildClass(Stmt.ClassDecl decl, Env env)
    {
        EmClass? super = null;
        if (decl.BaseName is not null)
        {
            if (!env.TryGet(decl.BaseName.Lexeme, out object? found) || found is not EmClass baseClass)
                throw new RuntimeError($"No class named {decl.BaseName.Lexeme}.");
            super = baseClass;
        }

        List<Stmt.VarDecl> fields =
            [.. decl.Members.OfType<Stmt.VarDecl>().Where(f => !f.IsStatic && f.Getter is null)];
        var constructor = decl.Members.OfType<Stmt.ConstructorDecl>().FirstOrDefault();

        // Trait-provided methods are merged in first, so the class's own definitions win.
        // On the CLR this would lower to interface default methods (§3.2); in a tree-walker
        // a merged table is the same thing with less ceremony.
        Dictionary<string, Stmt.FuncDecl> methods = [];
        List<string> required = [];

        foreach (var traitName in decl.Traits)
        {
            if (!env.TryGet(traitName.Lexeme, out object? found) || found is not EmClass trait)
                throw new RuntimeError($"No trait named {traitName.Lexeme}.");

            foreach (var (name, method) in trait.Methods)
                if (method.Body is not null) methods[name] = method;
                else required.Add(name);

            required.AddRange(trait.Unimplemented);
        }

        foreach (var method in decl.Members.OfType<Stmt.FuncDecl>().Where(m => !m.IsStatic))
        {
            if (method.Body is not null) methods[method.Name.Lexeme] = method;
            else required.Add(method.Name.Lexeme);
        }

        // Anything the base already provides counts as implemented.
        List<string> unimplemented = [..
            required.Distinct()
                    .Where(n => !methods.ContainsKey(n) && super?.FindMethod(n)?.Body is null)];

        var built = new EmClass(decl.Name.Lexeme, decl.Kind, super, fields, methods,
                                constructor, unimplemented, env);

        foreach (var property in decl.Members.OfType<Stmt.VarDecl>().Where(f => f.Getter is not null))
            built.Properties[property.Name.Lexeme] = property;

        foreach (var method in decl.Members.OfType<Stmt.FuncDecl>().Where(m => m.IsStatic))
            built.StaticMethods[method.Name.Lexeme] = method;

        // Static initialisers run once, when the type is declared.
        var staticScope = new Env(env);
        staticScope.Declare("Self", built);
        foreach (var field in decl.Members.OfType<Stmt.VarDecl>().Where(f => f.IsStatic))
            built.Statics[field.Name.Lexeme] =
                field.Init is null ? null : Evaluate(field.Init, staticScope);

        return built;
    }

    public object Instantiate(EmClass cls, List<object?> args)
    {
        if (cls.Kind == TypeKind.Trait)
            throw new RuntimeError(
                $"{cls.Name} is a trait, so it cannot be created directly.",
                $"Traits are mixed into a class:  class Dog with {cls.Name}");

        if (cls.Unimplemented.Count > 0)
            throw new RuntimeError(
                $"Cannot create {cls.Name} — {string.Join(", ", cls.Unimplemented)} has no implementation.",
                "Implement it here, or create a subclass that does.");

        var instance = new EmInstance(cls);

        // Field initialisers run in a scope where `self` already exists, so one field can
        // be defined in terms of another.
        var fieldScope = new Env(cls.Closure);
        fieldScope.Declare("self", instance);
        foreach (var field in cls.AllFields())
            instance.Fields[field.Name.Lexeme] =
                field.Init is null ? null : Evaluate(field.Init, fieldScope);

        var constructor = cls.Constructor;
        if (constructor is not null)
        {
            if (args.Count != constructor.Params.Count)
                throw new RuntimeError(
                    $"{cls.Name} takes {constructor.Params.Count} argument(s), got {args.Count}.");

            var scope = new Env(cls.Closure);
            scope.Declare("self", instance);
            for (int i = 0; i < constructor.Params.Count; i++)
                scope.Declare(constructor.Params[i].Name.Lexeme, args[i]);

            try { ExecuteBlock(constructor.Body, scope); }
            catch (ReturnSignal) { /* an early return from a constructor is allowed */ }
        }
        else if (args.Count > 0)
        {
            throw new RuntimeError(
                $"{cls.Name} has no constructor, so it takes no arguments.",
                $"Add one:  constructor(...) {{ ... }}");
        }

        return instance;
    }

    public object? CallMethod(
        Stmt.FuncDecl method, EmInstance receiver, Env closure, List<object?> args)
    {
        if (args.Count != method.Params.Count)
            throw new RuntimeError(
                $"{method.Name.Lexeme} takes {method.Params.Count} argument(s), got {args.Count}.");

        var scope = new Env(closure);
        scope.Declare("self", receiver);
        for (int i = 0; i < method.Params.Count; i++)
            scope.Declare(method.Params[i].Name.Lexeme, args[i]);

        try { ExecuteBlock(method.Body, scope); }
        catch (ReturnSignal r) { return r.Value; }
        return null;
    }

    /// <summary>
    /// Field first, then method. A bare <c>dog.speak</c> invokes the method rather than
    /// producing a reference to it, because parens are optional (§3.1) — the two spellings
    /// have to mean the same thing.
    /// </summary>
    private object? GetOrInvoke(EmInstance instance, Token name, List<object?> args)
    {
        if (args.Count == 0 && instance.Fields.TryGetValue(name.Lexeme, out object? value))
            return value;

        // A property is a var with a body: reading it runs the getter (§3.2). Callers
        // cannot tell it apart from a stored field, which is the whole point.
        if (args.Count == 0 && instance.Class.FindProperty(name.Lexeme) is { Getter: { } getter })
        {
            var scope = new Env(instance.Class.Closure);
            scope.Declare("self", instance);
            try { ExecuteBlock(getter, scope); }
            catch (ReturnSignal r) { return r.Value; }
            return null;
        }

        var method = instance.Class.FindMethod(name.Lexeme);
        if (method is not null)
            return CallMethod(method, instance, instance.Class.Closure, args);

        throw new RuntimeError(
            $"No member named {name.Lexeme} on {instance.Class.Name}.");
    }

    /// <summary>Type-level access: <c>Dog.from_shelter_id(42)</c>, <c>Vector3.zero</c>.</summary>
    private object? GetStatic(EmClass cls, Token name, List<object?> args)
    {
        if (args.Count == 0 && cls.OwnerOfStatic(name.Lexeme) is { } owner)
            return owner.Statics[name.Lexeme];

        if (cls.FindStaticMethod(name.Lexeme) is { } method)
        {
            if (args.Count != method.Params.Count)
                throw new RuntimeError(
                    $"{name.Lexeme} takes {method.Params.Count} argument(s), got {args.Count}.");

            var scope = new Env(cls.Closure);
            scope.Declare("Self", cls);
            for (int i = 0; i < method.Params.Count; i++)
                scope.Declare(method.Params[i].Name.Lexeme, args[i]);

            try { ExecuteBlock(method.Body!, scope); }
            catch (ReturnSignal r) { return r.Value; }
            return null;
        }

        throw new RuntimeError(
            $"No class member named {name.Lexeme} on {cls.Name}.",
            cls.FindMethod(name.Lexeme) is not null
                ? $"{name.Lexeme} belongs to an instance — call it on a {cls.Name} value."
                : null);
    }

    private void SetField(EmInstance instance, Token name, object? value)
    {
        if (instance.Class.FindProperty(name.Lexeme) is { } property)
        {
            if (property.Setter is null)
                throw new RuntimeError(
                    $"{name.Lexeme} has no set, so it cannot be assigned to.",
                    $"Add one:  var {name.Lexeme}: ... {{ get {{ ... }} set {{ ... }} }}");

            var scope = new Env(instance.Class.Closure);
            scope.Declare("self", instance);
            scope.Declare("value", value);
            try { ExecuteBlock(property.Setter, scope); }
            catch (ReturnSignal) { }
            return;
        }

        if (!instance.Fields.ContainsKey(name.Lexeme))
            throw new RuntimeError(
                $"No instance variable named {name.Lexeme} on {instance.Class.Name}.",
                $"Instance variables are declared in the class body:  var {name.Lexeme} = ...");

        instance.Fields[name.Lexeme] = value;
    }

    // ---- expressions ----------------------------------------------------

    private object? Evaluate(Expr expr, Env env) => expr switch
    {
        Expr.Literal l => l.Value,
        Expr.Grouping g => Evaluate(g.Inner, env),
        Expr.Variable v => Lookup(v.Name, env),
        Expr.Interpolation s => Interpolate(s, env),
        Expr.RangeExpr r => MakeRange(r, env),
        Expr.ArrayLiteral a => new EmArray([.. a.Items.Select(item => Evaluate(item, env))]),
        Expr.Index ix => EvaluateIndex(ix, env),
        Expr.Unary u => EvaluateUnary(u, env),
        Expr.Binary b => EvaluateBinary(b, env),
        Expr.Logical l => EvaluateLogical(l, env),
        Expr.IfExpr i => Truthy(Evaluate(i.Condition, env))
            ? Evaluate(i.Then, env)
            : Evaluate(i.Else, env),
        Expr.Lambda l => new EmLambda(l, env),
        Expr.Get g => EvaluateGet(g, env),
        Expr.Call c => EvaluateCall(c, env),
        _ => throw new RuntimeError($"Cannot evaluate {expr.GetType().Name}.")
    };

    private object? Lookup(Token name, Env env)
    {
        _line = name.Line;
        return env.TryGet(name.Lexeme, out object? value) ? value : throw Unknown(name);
    }

    private object? Interpolate(Expr.Interpolation node, Env env)
    {
        var sb = new StringBuilder();
        foreach (var part in node.Parts) sb.Append(Builtins.Display(Evaluate(part, env)));
        return sb.ToString();
    }

    private object? EvaluateIndex(Expr.Index ix, Env env)
    {
        _line = ix.Bracket.Line;
        object? target = Evaluate(ix.Target, env);
        object? position = Evaluate(ix.Position, env);

        if (position is not long i)
            throw new RuntimeError(
                $"An index must be an Int, got {Builtins.TypeName(position)}.");

        if (target is not EmArray array)
            throw new RuntimeError($"Cannot index {Builtins.TypeName(target)}.");

        if (i < 0 || i >= array.Items.Count)
            throw new RuntimeError(
                $"Index {i} is outside this array, which holds {array.Items.Count} item(s).",
                array.Items.Count == 0
                    ? "The array is empty."
                    : $"Valid positions run from 0 to {array.Items.Count - 1}.");

        return array.Items[(int)i];
    }

    private object? MakeRange(Expr.RangeExpr r, Env env)
    {
        object? start = Evaluate(r.Start, env);
        object? end = Evaluate(r.End, env);
        if (start is long a && end is long b) return new EmRange(a, b);
        throw new RuntimeError(
            $"A range needs two Ints, got {Builtins.TypeName(start)} and {Builtins.TypeName(end)}.");
    }

    private object? EvaluateUnary(Expr.Unary u, Env env)
    {
        _line = u.Op.Line;
        object? right = Evaluate(u.Right, env);
        return u.Op.Type switch
        {
            TokenType.Not => !Truthy(right),
            // The (object) cast matters: without it C# unifies the arms of this inner
            // switch, long widens to double, and -7 becomes a Float. The outer switch is
            // target-typed to object? and does not have the problem; a nested one does.
            TokenType.Minus => right switch
            {
                long i => (object)(-i),
                double d => -d,
                _ => throw new RuntimeError($"Cannot negate {Builtins.TypeName(right)}.")
            },
            _ => throw new RuntimeError($"Unknown operator {u.Op.Lexeme}.")
        };
    }

    private object? EvaluateBinary(Expr.Binary b, Env env)
    {
        _line = b.Op.Line;
        object? left = Evaluate(b.Left, env);
        object? right = Evaluate(b.Right, env);

        return b.Op.Type switch
        {
            TokenType.Equal => AreEqual(left, right),
            TokenType.NotEqual => !AreEqual(left, right),
            TokenType.Less or TokenType.Greater or TokenType.LessEqual or TokenType.GreaterEqual
                => Compare(left, right, b.Op),
            _ => Arithmetic(left, b.Op.Type, right, b.Op)
        };
    }

    /// <summary><c>and</c> and <c>or</c> short-circuit, so they cannot go through Binary.</summary>
    private object? EvaluateLogical(Expr.Logical l, Env env)
    {
        object? left = Evaluate(l.Left, env);
        if (l.Op.Type == TokenType.Or && Truthy(left)) return left;
        if (l.Op.Type == TokenType.And && !Truthy(left)) return left;
        return Evaluate(l.Right, env);
    }

    private object? EvaluateGet(Expr.Get g, Env env)
    {
        _line = g.Name.Line;
        object? target = Evaluate(g.Target, env);

        if (target is EmInstance instance) return GetOrInvoke(instance, g.Name, []);
        if (target is EmClass cls) return GetStatic(cls, g.Name, []);

        // A property-style access is a zero-argument method call: 5.even?, "hi".length
        return Builtins.InvokeMethod(this, target, g.Name.Lexeme, []);
    }

    private object? EvaluateCall(Expr.Call c, Env env)
    {
        List<object?> args = [.. c.Args.Select(a => Evaluate(a, env))];
        if (c.Trailing is not null) args.Add(new EmLambda(c.Trailing, env));

        // A method call is a Get in callee position — evaluate the receiver, then dispatch.
        if (c.Callee is Expr.Get get)
        {
            object? target = Evaluate(get.Target, env);
            if (target is EmInstance instance) return GetOrInvoke(instance, get.Name, args);
            if (target is EmClass cls) return GetStatic(cls, get.Name, args);
            return Builtins.InvokeMethod(this, target, get.Name.Lexeme, args);
        }

        object? callee = Evaluate(c.Callee, env);
        if (callee is not ICallable callable)
            throw new RuntimeError($"{Builtins.TypeName(callee)} is not something you can call.");

        return callable.Call(this, args);
    }

    // ---- operators ------------------------------------------------------

    private static object Arithmetic(object? left, TokenType op, object? right, Token token)
    {
        if (op == TokenType.Plus && (left is string || right is string))
            return Builtins.Display(left) + Builtins.Display(right);

        // Written as statements rather than switch expressions on purpose: a switch
        // expression unifies its arms, so one `double` arm silently widens every `long`
        // one. That bug has already shipped twice here.
        if (left is long a && right is long b)
        {
            switch (op)
            {
                case TokenType.Plus: return a + b;
                case TokenType.Minus: return a - b;
                case TokenType.Star: return a * b;
                case TokenType.StarStar: return IntPower(a, b, token);

                // `/` always gives a Float, even on two Ints. C# and Java quietly floor
                // here, so 7 / 2 is 3 and a beginner has no idea why — Python 3 broke
                // from that deliberately, and this follows it.
                case TokenType.Slash:
                    if (b == 0) throw DivideByZero();
                    return (double)a / b;

                // `//` and `%` floor toward negative infinity, as a matched pair, so
                // a // b * b + a % b == a holds. C# truncates toward zero instead, which
                // makes -7 % 2 come out as -1 and breaks `n % 2 == 1` for negatives.
                case TokenType.SlashSlash:
                    if (b == 0) throw DivideByZero();
                    return (long)Math.Floor((double)a / b);

                case TokenType.Percent:
                    if (b == 0) throw DivideByZero();
                    return a - b * (long)Math.Floor((double)a / b);
            }
            throw new RuntimeError($"Unknown operator {token.Lexeme}.");
        }

        if (IsNumber(left) && IsNumber(right))
        {
            double x = ToDouble(left), y = ToDouble(right);
            switch (op)
            {
                case TokenType.Plus: return x + y;
                case TokenType.Minus: return x - y;
                case TokenType.Star: return x * y;
                case TokenType.StarStar: return Math.Pow(x, y);

                case TokenType.Slash:
                    if (y == 0) throw DivideByZero();
                    return x / y;

                case TokenType.SlashSlash:
                    if (y == 0) throw DivideByZero();
                    return Math.Floor(x / y);

                case TokenType.Percent:
                    if (y == 0) throw DivideByZero();
                    return x - y * Math.Floor(x / y);
            }
            throw new RuntimeError($"Unknown operator {token.Lexeme}.");
        }

        throw new RuntimeError(
            $"Cannot use {token.Lexeme} on {Builtins.TypeName(left)} and {Builtins.TypeName(right)}.");
    }

    private static bool Compare(object? left, object? right, Token op)
    {
        if (!IsNumber(left) || !IsNumber(right))
            throw new RuntimeError(
                $"Cannot compare {Builtins.TypeName(left)} with {Builtins.TypeName(right)}.");

        int cmp = ToDouble(left).CompareTo(ToDouble(right));
        return op.Type switch
        {
            TokenType.Less => cmp < 0,
            TokenType.Greater => cmp > 0,
            TokenType.LessEqual => cmp <= 0,
            _ => cmp >= 0
        };
    }

    private static bool AreEqual(object? a, object? b) =>
        a is null && b is null || (a?.Equals(b) ?? false);

    /// <summary>
    /// Only <c>false</c> and <c>nothing</c> are falsy. Notably 0 and "" are not — a
    /// number is not a disguised boolean, which is a lie C-family languages tell.
    /// </summary>
    private static bool Truthy(object? value) => value switch
    {
        null => false,
        bool b => b,
        _ => true
    };

    private static TokenType CompoundOp(TokenType assign) => assign switch
    {
        TokenType.PlusAssign => TokenType.Plus,
        TokenType.MinusAssign => TokenType.Minus,
        TokenType.StarAssign => TokenType.Star,
        _ => TokenType.Slash,
    };

    private static bool IsNumber(object? v) => v is long or double;
    private static double ToDouble(object? v) => v is long i ? i : (double)v!;

    /// <summary>
    /// Int ** Int stays an Int, which is the point of having the operator at all —
    /// <c>Math.pow</c> goes through doubles and can only give a Float back. A negative
    /// exponent produces a Float, because the result is a fraction. Overflow is reported
    /// rather than wrapping silently.
    /// </summary>
    private static object IntPower(long baseValue, long exponent, Token token)
    {
        if (exponent < 0) return Math.Pow(baseValue, exponent);

        long result = 1;
        try
        {
            checked
            {
                for (long i = 0; i < exponent; i++) result *= baseValue;
            }
        }
        catch (OverflowException)
        {
            throw new RuntimeError(
                $"{baseValue} ** {exponent} is too large to hold in an Int.",
                "Use Floats if you need a number this big:  "
                + $"{baseValue}.to_float ** {exponent}");
        }

        return result;
    }

    private static RuntimeError DivideByZero() =>
        new("Cannot divide by zero.", "Check the divisor before dividing.");

    private static RuntimeError Unknown(Token name) =>
        new($"No variable named {name.Lexeme}.",
            $"Declare it first: var {name.Lexeme} = ...");

    // ---- callables ------------------------------------------------------

    internal sealed class ReturnSignal(object? value) : Exception
    {
        public object? Value { get; } = value;
    }

    private sealed class NativeFunction(string name, Func<List<object?>, object?> fn) : ICallable
    {
        public object? Call(Interpreter interpreter, List<object?> args) => fn(args);
        public override string ToString() => $"<kernel {name}>";
    }

    private sealed class EmFunction(
        string name, List<Param> parameters, List<Stmt> body, Env closure) : ICallable
    {
        public object? Call(Interpreter interpreter, List<object?> args)
        {
            if (args.Count != parameters.Count)
                throw new RuntimeError(
                    $"{name} takes {parameters.Count} argument(s), got {args.Count}.");

            var scope = new Env(closure);
            for (int i = 0; i < parameters.Count; i++)
                scope.Declare(parameters[i].Name.Lexeme, args[i]);

            try { interpreter.ExecuteBlock(body, scope); }
            catch (ReturnSignal r) { return r.Value; }
            return null;
        }

        public override string ToString() => $"<func {name}>";
    }

    private sealed class EmLambda(Expr.Lambda node, Env closure) : ICallable
    {
        public object? Call(Interpreter interpreter, List<object?> args)
        {
            var scope = new Env(closure);
            for (int i = 0; i < node.Params.Count; i++)
                scope.Declare(node.Params[i].Name.Lexeme, i < args.Count ? args[i] : null);

            // A single-expression body is its own value; a block of statements produces
            // one only by saying `return`. The same shape as `if … then … else`, which
            // is why blocks never needed value semantics.
            if (node.Body is [Stmt.ExprStmt only])
                return interpreter.Evaluate(only.Expression, scope);

            // Caught here rather than by an enclosing function, so `return` inside a
            // block returns from the block — not Ruby's non-local return, which surprises
            // everyone exactly once.
            try { interpreter.ExecuteBlock(node.Body, scope); }
            catch (ReturnSignal r) { return r.Value; }
            return null;
        }

        public override string ToString() => "<block>";
    }
}
