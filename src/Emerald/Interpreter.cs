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
            DeclareFunctions(program);

            // Function declarations are skipped here: DeclareFunctions has already put
            // them in, gathered into overload sets. Executing them again would declare
            // each on its own and replace the set with whichever came last.
            foreach (var stmt in program)
                if (stmt is not Stmt.FuncDecl) Execute(stmt, _globals);
        }
        catch (RuntimeError error)
        {
            if (error.Line == 0) error.Line = _line;
            throw;
        }
        catch (ThrownError thrown)
        {
            if (thrown.Line == 0) thrown.Line = _line;
            throw;
        }
    }

    /// <summary>
    /// Declares everything a program defines without running what it <em>does</em>.
    ///
    /// <c>emerald test</c> needs the functions and types a test calls, but must not run
    /// main.em's own work: a test run that printed the program's output and then blocked
    /// waiting for its input would be unusable. So declarations run — functions, types,
    /// and module-level variables a test may rely on — and statements do not.
    /// </summary>
    public void LoadDeclarations(List<Stmt> program)
    {
        DeclareFunctions(program);

        foreach (var stmt in program)
            if (stmt is Stmt.ClassDecl or Stmt.VarDecl)
                Execute(stmt, _globals);
    }

    /// <summary>Calls a nullary function, or a static method when an owner is named.</summary>
    public object? CallNamed(string? owner, string name)
    {
        if (owner is null)
        {
            if (!_globals.TryGet(name, out object? found) || found is not ICallable callable)
                throw new RuntimeError($"No function named {name}.");
            return callable.Call(this, []);
        }

        if (!_globals.TryGet(owner, out object? type) || type is not EmClass cls)
            throw new RuntimeError($"No type named {owner}.");

        return GetStatic(cls, new Token(TokenType.Identifier, name, null, 0), []);
    }

    /// <summary>
    /// Hoists every top-level function, gathering same-named ones into one overload set
    /// (§3.2). Declared before anything runs so a file reads top to bottom and mutual
    /// recursion works — and so the checker and the runtime agree about what exists.
    /// </summary>
    private void DeclareFunctions(List<Stmt> program)
    {
        Dictionary<string, EmOverloads> sets = [];

        foreach (var stmt in program)
        {
            if (stmt is not Stmt.FuncDecl fn) continue;
            var built = new EmFunction(fn.Name.Lexeme, fn.Params, fn.Body, _globals);

            if (sets.TryGetValue(fn.Name.Lexeme, out var set)) { set.Add(built); continue; }

            if (_globals.TryGet(fn.Name.Lexeme, out object? already)
                && already is EmFunction first)
            {
                var combined = new EmOverloads(fn.Name.Lexeme);
                combined.Add(first);
                combined.Add(built);
                sets[fn.Name.Lexeme] = combined;
                _globals.Declare(fn.Name.Lexeme, combined);
                continue;
            }

            _globals.Declare(fn.Name.Lexeme, built);
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
                {
                    try { ExecuteBlock(w.Body, new Env(env)); }
                    catch (BreakSignal) { break; }
                    catch (ContinueSignal) { continue; }
                }
                break;

            case Stmt.Break:
                throw new BreakSignal();

            case Stmt.Continue:
                throw new ContinueSignal();

            case Stmt.For f:
                ExecuteFor(f, env);
                break;

            case Stmt.FuncDecl fn:
                env.Declare(fn.Name.Lexeme, new EmFunction(fn.Name.Lexeme, fn.Params, fn.Body, env));
                break;

            case Stmt.ClassDecl c:
                env.Declare(c.Name.Lexeme, BuildClass(c, env));
                break;

            case Stmt.EnumDecl e:
                env.Declare(e.Name.Lexeme, BuildEnum(e, env));
                break;

            case Stmt.Throw t:
                _line = t.Keyword.Line;
                throw new ThrownError(AsError(Evaluate(t.Value, env), t.Keyword));

            case Stmt.Assert a:
                ExecuteAssert(a, env);
                break;

            case Stmt.TryCatch tc:
                ExecuteTryCatch(tc, env);
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
                    updated = Operate(owner.Statics[field.Name.Lexeme],
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
                newValue = Operate(current, CompoundOp(a.Op.Type), newValue, a.Op);
            }
            SetField(instance, field.Name, newValue);
            return;
        }

        if (a.Target is Expr.Index index)
        {
            ExecuteIndexAssign(a, index, env);
            return;
        }

        if (a.Target is not Expr.Variable target)
            throw new RuntimeError("Only a variable or a member can be assigned to.");

        object? value = Evaluate(a.Value, env);

        if (a.Op.Type != TokenType.Assign)
        {
            if (!env.TryGet(target.Name.Lexeme, out object? current))
                throw Unknown(target.Name);

            value = Operate(current, CompoundOp(a.Op.Type), value, a.Op);
        }

        if (!env.TryAssign(target.Name.Lexeme, value)) throw Unknown(target.Name);
    }

    /// <summary>
    /// <c>a[i] = value</c>, and the compound forms. A list writes in place; a user type
    /// writes through <c>set_at</c>, the setter half of Indexable.
    /// </summary>
    private void ExecuteIndexAssign(Stmt.Assign a, Expr.Index index, Env env)
    {
        object? target = Evaluate(index.Target, env);
        object? position = Evaluate(index.Position, env);
        object? value = Evaluate(a.Value, env);

        if (target is EmDict dict)
        {
            object key = position
                ?? throw new RuntimeError("nothing cannot be a dictionary key.");

            if (a.Op.Type != TokenType.Assign)
                value = Operate(dict.Get(key), CompoundOp(a.Op.Type), value, a.Op);

            dict.Set(key, value);
            return;
        }

        if (target is EmInstance instance)
        {
            var setAt = instance.Class.FindMethod(Prelude.SetAtMethod)
                ?? throw new RuntimeError(
                    $"{instance.Class.Name} cannot be written to by position.",
                    $"Define {Prelude.SetAtMethod}(index, value) to allow "
                    + $"{instance.Class.Name}[i] = value.");

            // A compound assignment reads through at(), combines, then writes back — so
            // `grid[0] += 1` needs both halves of the trait, not just the setter.
            if (a.Op.Type != TokenType.Assign)
            {
                var at = instance.Class.FindMethod(Prelude.AtMethod)
                    ?? throw new RuntimeError(
                        $"{instance.Class.Name} cannot be read by position.",
                        $"{a.Op.Lexeme} has to read the old value before it can write a new one.");

                object? current = CallMethod(at, instance, instance.Class.Closure, [position]);
                value = Operate(current, CompoundOp(a.Op.Type), value, a.Op);
            }

            CallMethod(setAt, instance, instance.Class.Closure, [position, value]);
            return;
        }

        if (position is not long i)
            throw new RuntimeError(
                $"An index must be an Int, got {Builtins.TypeName(position)}.");

        if (target is not EmList list)
            throw new RuntimeError($"Cannot index {Builtins.TypeName(target)}.");

        if (i < 0 || i >= list.Items.Count)
            throw new RuntimeError(
                $"Index {i} is outside this list, which holds {list.Items.Count} item(s).",
                list.Items.Count == 0
                    ? "The list is empty."
                    : $"Valid positions run from 0 to {list.Items.Count - 1}.");

        if (a.Op.Type != TokenType.Assign)
            value = Operate(list.Items[(int)i], CompoundOp(a.Op.Type), value, a.Op);

        list.Items[(int)i] = value;
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

    /// <summary>
    /// <c>assert total == 10</c>.
    ///
    /// The point of it is the failure message. §3.5 wants
    /// <c>assert clamp(15, 0, 10) == 10</c> to report "was 15", which needs the
    /// <em>expression</em> and not only the <c>false</c> it produced — the reason §3.8
    /// filed assert as a macro. Reading the tree here gets the same answer with no macro
    /// system, and the cost is that assert is compiler-known rather than something a
    /// library could have written.
    /// </summary>
    private void ExecuteAssert(Stmt.Assert statement, Env env)
    {
        _line = statement.Keyword.Line;

        // A comparison is unpacked so both sides can be reported. Each is evaluated once:
        // running them again to print them would repeat any effect they had, and an
        // assertion that changes the program while explaining itself is worse than none.
        if (statement.Condition is Expr.Binary
            {
                Op.Type: TokenType.Equal or TokenType.NotEqual or TokenType.Less
                         or TokenType.Greater or TokenType.LessEqual or TokenType.GreaterEqual
            } comparison)
        {
            object? left = Evaluate(comparison.Left, env);
            object? right = Evaluate(comparison.Right, env);

            bool held = comparison.Op.Type switch
            {
                TokenType.Equal => Same(left, right),
                TokenType.NotEqual => !Same(left, right),
                _ => Ordering(left, right, comparison.Op),
            };

            if (held) return;

            throw new ThrownError(new EmError(
                $"Assertion failed:  {Source.Of(statement.Condition)}"
                + $"\n    left  was {Builtins.Display(left)}"
                + $"\n    right was {Builtins.Display(right)}"))
            { Line = statement.Keyword.Line, FromAssertion = true };
        }

        if (Truthy(Evaluate(statement.Condition, env))) return;

        throw new ThrownError(
            new EmError($"Assertion failed:  {Source.Of(statement.Condition)}"))
        { Line = statement.Keyword.Line, FromAssertion = true };
    }

    private void ExecuteFor(Stmt.For f, Env env)
    {
        _line = f.Variable.Line;
        object? iterable = Evaluate(f.Iterable, env);

        // The three things a loop can walk. A string yields its characters as graphemes,
        // matching .chars — an emoji is one turn of the loop, not two.
        IEnumerable<object?> items = iterable switch
        {
            EmRange range => range.Select(i => (object?)i),
            EmList list => list.Items,
            EmSet set => set.Members,
            string text => Builtins.CharactersOf(text),
            _ => throw new RuntimeError(
                $"Cannot loop over {Builtins.TypeName(iterable)}.",
                "Loop over a range (1..5), a list, or a string."),
        };

        // A list copied before walking it, so `for x in xs { xs.add(...) }` terminates
        // rather than growing under the loop. A student writing that has made a mistake,
        // but hanging is a far worse way to learn it than a loop that simply ends.
        if (iterable is EmList) items = [.. items];

        foreach (object? item in items)
        {
            // A fresh scope each turn (§3.3), so a closure made inside the body captures
            // that turn's value rather than sharing one variable with every other turn.
            var scope = new Env(env);
            scope.Declare(f.Variable.Lexeme, item);

            try { ExecuteBlock(f.Body, scope); }
            catch (BreakSignal) { break; }
            catch (ContinueSignal) { continue; }
        }
    }

    private void ExecuteBlock(List<Stmt> body, Env env)
    {
        foreach (var stmt in body) Execute(stmt, env);
    }

    /// <summary>
    /// <c>throw "oops"</c> is shorthand for <c>throw Error("oops")</c> — a spelling, not
    /// a second concept, so both arrive here as one thing.
    /// </summary>
    private static EmError AsError(object? value, Token keyword) => value switch
    {
        EmError error => error,
        string message => new EmError(message),
        _ => throw new RuntimeError(
            $"Cannot throw {Builtins.TypeName(value)}.",
            "Throw an Error, or a String to be wrapped in one:  throw Error(\"...\")")
    };

    /// <summary>
    /// Catches both a thrown Emerald value and the interpreter's own runtime errors, so a
    /// failed <c>to_int</c> can be handled rather than merely avoided. Deliberately does
    /// not catch <c>exit</c> or a <c>return</c> unwinding through — neither is a failure.
    /// </summary>
    private void ExecuteTryCatch(Stmt.TryCatch node, Env env)
    {
        EmError caught;
        try
        {
            ExecuteBlock(node.Body, new Env(env));
            return;
        }
        catch (ThrownError thrown) { caught = thrown.Value; }
        catch (RuntimeError failure) { caught = new EmError(failure.Message); }

        var handler = new Env(env);
        handler.Declare(node.CaughtName.Lexeme, caught);
        ExecuteBlock(node.Handler, handler);
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

    /// <summary>
    /// An enum is an EmClass whose statics are its values, so <c>Colour.RED</c> resolves
    /// through the same static lookup a class uses and nothing downstream needs to know
    /// the difference. <c>values</c> is added alongside, because asking an enum for its
    /// members is the one thing you cannot write yourself.
    /// </summary>
    private static EmClass BuildEnum(Stmt.EnumDecl decl, Env env)
    {
        var built = new EmClass(decl.Name.Lexeme, TypeKind.Enum, null, [], [], null, [], env);

        for (int i = 0; i < decl.Members.Count; i++)
            built.Statics[decl.Members[i].Lexeme] =
                new EmEnumValue(decl.Name.Lexeme, decl.Members[i].Lexeme, i);

        built.Statics["values"] = new EmList([.. built.Statics.Values]);
        return built;
    }

    public object Instantiate(EmClass cls, List<object?> args)
    {
        if (cls.Kind == TypeKind.Trait)
            throw new RuntimeError(
                $"{cls.Name} is a trait, so it cannot be created directly.",
                $"Traits are mixed into a class:  class Dog with {cls.Name}");

        if (cls.Kind == TypeKind.Enum)
            throw new RuntimeError(
                $"{cls.Name} is an enum, so it has only the values it declares.",
                $"Use one of them:  {cls.Name}.{cls.Statics.Keys.FirstOrDefault() ?? "FIRST"}");

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
            var scope = new Env(cls.Closure);
            scope.Declare("self", instance);
            BindParameters(constructor.Params, args, scope, cls.Name);

            try { ExecuteBlock(constructor.Body, scope); }
            catch (ReturnSignal) { /* an early return from a constructor is allowed */ }
        }
        else if (cls.Kind == TypeKind.Struct)
        {
            // The implicit constructor (§3.2): a struct's fields, positionally, in
            // declaration order. Mirrors the checker's ConstructorParams exactly — if these
            // two ever disagree, the checker accepts calls the runtime then rejects.
            List<Stmt.VarDecl> fields = [.. cls.AllFields()];

            if (args.Count != fields.Count)
                throw new RuntimeError(
                    $"{cls.Name} takes {fields.Count} argument(s), got {args.Count}.",
                    fields.Count == 0
                        ? null
                        : $"Its fields are {string.Join(", ", fields.Select(f => f.Name.Lexeme))}, "
                          + "and they are filled in that order.");

            for (int i = 0; i < fields.Count; i++)
                instance.Fields[fields[i].Name.Lexeme] = args[i];
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
        var scope = new Env(closure);
        scope.Declare("self", receiver);
        BindParameters(method.Params, args, scope, method.Name.Lexeme);

        try { ExecuteBlock(method.Body, scope); }
        catch (ReturnSignal r) { return r.Value; }
        return null;
    }

    /// <summary>
    /// Binds arguments to parameters, filling anything the caller left off from its
    /// default (§3.2).
    ///
    /// Defaults are evaluated <em>per call</em>, not once at declaration. Python evaluates
    /// once, which is why <c>def f(x=[])</c> shares one list between every call that omits
    /// it — a bug so well known it has a name, in a place a beginner has no reason to
    /// look. Evaluating here also costs nothing and means a default may refer to a
    /// parameter to its left, since those are already in this scope.
    /// </summary>
    private void BindParameters(
        List<Param> parameters, List<object?> args, Env scope, string what)
    {
        int least = parameters.TakeWhile(p => p.Default is null).Count();

        if (args.Count < least || args.Count > parameters.Count)
        {
            string wanted = least == parameters.Count
                ? $"{parameters.Count} argument(s)"
                : $"between {least} and {parameters.Count} argument(s)";
            throw new RuntimeError($"{what} takes {wanted}, got {args.Count}.");
        }

        for (int i = 0; i < parameters.Count; i++)
            scope.Declare(parameters[i].Name.Lexeme,
                          i < args.Count ? args[i] : Evaluate(parameters[i].Default!, scope));
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
            var scope = new Env(cls.Closure);
            scope.Declare("Self", cls);
            BindParameters(method.Params, args, scope, name.Lexeme);

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
        Expr.ListLiteral a => new EmList([.. a.Items.Select(item => Evaluate(item, env))]),
        Expr.DictLiteral d => MakeDict(d, env),
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

        // A dictionary decides for itself what a key is, so it comes before the Int
        // requirement. Missing gives nothing, which is what makes d[k].or(0) the idiom.
        if (target is EmDict dict)
            return position is null
                ? throw new RuntimeError("nothing cannot be a dictionary key.")
                : dict.Get(position);

        // A user type indexes through Indexable. Checked before the Int requirement,
        // because at() decides for itself what an index is — a Grid may want a String key
        // even though lists never will.
        if (target is EmInstance instance)
        {
            var at = instance.Class.FindMethod(Prelude.AtMethod)
                ?? throw new RuntimeError(
                    $"{instance.Class.Name} cannot be indexed with [].",
                    $"Mix in {Prelude.IndexableTrait} and define {Prelude.AtMethod}.");

            return CallMethod(at, instance, instance.Class.Closure, [position]);
        }

        if (position is not long i)
            throw new RuntimeError(
                $"An index must be an Int, got {Builtins.TypeName(position)}.");

        if (target is not EmList list)
            throw new RuntimeError($"Cannot index {Builtins.TypeName(target)}.");

        if (i < 0 || i >= list.Items.Count)
            throw new RuntimeError(
                $"Index {i} is outside this list, which holds {list.Items.Count} item(s).",
                list.Items.Count == 0
                    ? "The list is empty."
                    : $"Valid positions run from 0 to {list.Items.Count - 1}.");

        return list.Items[(int)i];
    }

    private EmDict MakeDict(Expr.DictLiteral literal, Env env)
    {
        _line = literal.Bracket.Line;
        var dict = new EmDict();

        foreach (var entry in literal.Entries)
        {
            object? key = Evaluate(entry.Key, env)
                ?? throw new RuntimeError("nothing cannot be a dictionary key.");
            dict.Set(key, Evaluate(entry.Value, env));
        }

        return dict;
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
            TokenType.Equal => Same(left, right),
            TokenType.NotEqual => !Same(left, right),
            TokenType.Less or TokenType.Greater or TokenType.LessEqual or TokenType.GreaterEqual
                => Ordering(left, right, b.Op),
            _ => Operate(left, b.Op.Type, right, b.Op)
        };
    }

    /// <summary>
    /// An arithmetic operator, dispatched to a method when the left side is a user type
    /// (§3.2). Everything else falls through to the built-in numeric behaviour.
    ///
    /// This has to be an instance method — calling a user's <c>add</c> needs the
    /// interpreter — which is why <see cref="Arithmetic"/> stays static behind it.
    /// </summary>
    private object? Operate(object? left, TokenType op, object? right, Token token)
    {
        if (left is not EmInstance instance || !Prelude.Operators.TryGetValue(op, out var entry))
            return Arithmetic(left, op, right, token);

        var method = instance.Class.FindMethod(entry.Method);
        if (method is null)
            throw new RuntimeError(
                $"{instance.Class.Name} does not define {token.Lexeme}.",
                $"Operators are methods here. Mix in {entry.Trait} and define {entry.Method}.");

        return CallMethod(method, instance, instance.Class.Closure, [right]);
    }

    /// <summary>
    /// <c>==</c>. A type that mixes in Equatable says what sameness means; one that does
    /// not is compared by identity. <c>!=</c> is always the negation of this, so the two
    /// can never be made to disagree.
    /// </summary>
    private bool Same(object? left, object? right)
    {
        if (left is EmInstance instance
            && instance.Class.FindMethod(Prelude.EqualsMethod) is { } method)
            return Truthy(CallMethod(method, instance, instance.Class.Closure, [right]));

        return AreEqual(left, right);
    }

    /// <summary>
    /// <c>&lt;</c>, <c>&gt;</c>, <c>&lt;=</c>, <c>&gt;=</c> — all four read the sign of one
    /// number, so a type implements Ordered once and gets the set.
    /// </summary>
    private bool Ordering(object? left, object? right, Token op)
    {
        if (left is EmInstance instance)
        {
            var method = instance.Class.FindMethod(Prelude.CompareMethod)
                ?? throw new RuntimeError(
                    $"{instance.Class.Name} cannot be ordered with {op.Lexeme}.",
                    $"Mix in {Prelude.OrderedTrait} and define {Prelude.CompareMethod}.");

            object? verdict = CallMethod(method, instance, instance.Class.Closure, [right]);
            if (verdict is not long sign)
                throw new RuntimeError(
                    $"{instance.Class.Name}.{Prelude.CompareMethod} gave back "
                    + $"{Builtins.TypeName(verdict)}, but ordering reads an Int.");

            return SignSatisfies(sign, op);
        }

        // Strings order lexicographically, by ordinal so the result never depends on the
        // machine's locale — the same program must sort the same way everywhere.
        if (left is string a && right is string b)
            return SignSatisfies(string.CompareOrdinal(a, b), op);

        return Compare(left, right, op);
    }

    private static bool SignSatisfies(long sign, Token op) => op.Type switch
    {
        TokenType.Less => sign < 0,
        TokenType.Greater => sign > 0,
        TokenType.LessEqual => sign <= 0,
        _ => sign >= 0
    };

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
            throw new RuntimeError($"{Builtins.TypeName(callee)} cannot be called.");

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
    /// <summary>
    /// Whether a value could have been declared as this type. Used only to choose between
    /// overloads, where the checker has already guaranteed at most one can match — so this
    /// answers "is this one of them", never "which is best".
    /// </summary>
    private static bool Matches(TypeRef declared, object? value)
    {
        string name = declared.Name.Lexeme;

        if (value is null) return declared.Nullable || name == "Nothing";

        return name switch
        {
            "Int" => value is long,

            // An Int is usable where a Float is wanted, the same widening Accepts allows.
            "Float" => value is double or long,

            "String" => value is string,
            "Bool" => value is bool,
            "Range" => value is EmRange,
            "List" => value is EmList,
            "Dictionary" => value is EmDict,
            "Set" => value is EmSet,
            "Nothing" => false,

            _ => value switch
            {
                EmInstance instance => IsA(instance.Class, name),
                EmEnumValue enumValue => enumValue.Type == name,
                _ => false,
            },
        };
    }

    private static bool IsA(EmClass? cls, string name) =>
        cls is not null && (cls.Name == name || IsA(cls.Super, name));

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
                "Floats hold numbers this large:  "
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

    /// <summary>
    /// Several functions of one name (§3.2). The checker has already refused any pair a
    /// call could not tell apart, so picking the first that fits is not a "best match"
    /// rule — at most one can ever fit.
    ///
    /// Dispatch happens here, on the values, rather than being resolved by the checker and
    /// recorded: the tree has nowhere to carry a resolution, and a side table threaded
    /// from the checker to the interpreter would be a second place for the two to
    /// disagree about what a call means.
    /// </summary>
    private sealed class EmOverloads(string name) : ICallable
    {
        private readonly List<EmFunction> _alternatives = [];

        public void Add(EmFunction fn) => _alternatives.Add(fn);

        public object? Call(Interpreter interpreter, List<object?> args)
        {
            foreach (var candidate in _alternatives)
                if (candidate.Fits(args)) return candidate.Call(interpreter, args);

            throw new RuntimeError(
                $"No version of {name} takes these arguments.",
                $"It has {_alternatives.Count} versions, and none of them matches.");
        }

        public override string ToString() => $"<func {name}, {_alternatives.Count} versions>";
    }

    internal sealed class ReturnSignal(object? value) : Exception
    {
        public object? Value { get; } = value;
    }

    /// <summary>
    /// <c>break</c> and <c>continue</c>, carried the same way <c>return</c> is. The
    /// checker has already refused either one outside a loop, and refused either one
    /// crossing a function boundary, so nothing here can escape past its loop.
    /// </summary>
    private sealed class BreakSignal : Exception;
    private sealed class ContinueSignal : Exception;

    private sealed class NativeFunction(string name, Func<List<object?>, object?> fn) : ICallable
    {
        public object? Call(Interpreter interpreter, List<object?> args) => fn(args);
        public override string ToString() => $"<kernel {name}>";
    }

    private sealed class EmFunction(
        string name, List<Param> parameters, List<Stmt> body, Env closure) : ICallable
    {
        public List<Param> Parameters => parameters;

        /// <summary>
        /// Whether this version can take these values. Arity first, since it settles most
        /// of them; then the declared type of each position against what actually arrived.
        /// </summary>
        public bool Fits(List<object?> args)
        {
            int least = parameters.TakeWhile(p => p.Default is null).Count();
            if (args.Count < least || args.Count > parameters.Count) return false;

            for (int i = 0; i < args.Count; i++)
                if (parameters[i].Type is { } declared && !Matches(declared, args[i]))
                    return false;

            return true;
        }

        public object? Call(Interpreter interpreter, List<object?> args)
        {
            var scope = new Env(closure);
            interpreter.BindParameters(parameters, args, scope, name);

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
