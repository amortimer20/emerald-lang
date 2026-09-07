using System.Text;

namespace Emerald;

/// <summary>
/// Tree -> behavior. A tree-walking interpreter: each node type knows how to evaluate
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

        // Display is static and has no interpreter to call a method with, so it is handed
        // one. Without this a type could declare to_string and nothing would ever call it,
        // which is how printing a class gave <Money> while every built-in gave its text.
        Builtins.Stringify = OwnToString;
    }

    /// <summary>
    /// A value's own <c>to_string</c>, or null where its type declares none — which is
    /// what leaves the plain <c>&lt;Money&gt;</c> form in place for a type that has not
    /// said how it should read.
    ///
    /// The checker holds a declared one to no parameters and a String return, so the cast
    /// here is not a hope. A trait's default and an inherited one both count, because
    /// finding a method is one question with one answer.
    /// </summary>
    private string? OwnToString(object? value) => value switch
    {
        EmInstance instance
            when instance.Class.FindMethod(Builtins.ToStringMethod) is { } method
            => CallMethod(method, instance, instance.Class.Closure, []) as string,

        EmEnumValue enumValue
            when enumValue.Owner?.FindMethod(Builtins.ToStringMethod) is { } method
            => CallEnumMethod(method, enumValue, enumValue.Owner, []) as string,

        _ => null,
    };

    public void Run(List<Stmt> program)
    {
        try
        {
            // Functions are declared before anything runs, matching the checker, so a
            // file reads top to bottom without forward declarations and mutual recursion
            // works. Without this the checker accepts programs the runtime then rejects.
            DeclareFunctions(program);
            DeclareTypes(program);

            // Function and type declarations are skipped here: both have been hoisted
            // above — functions gathered into overload sets, types built in dependency
            // order. Executing either again would declare it a second time.
            foreach (var stmt in program)
                if (stmt is not (Stmt.FuncDecl or Stmt.ClassDecl)) Execute(stmt, _globals);
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
        DeclareTypes(program);

        foreach (var stmt in program)
            if (stmt is Stmt.VarDecl)
                Execute(stmt, _globals);
    }

    /// <summary>
    /// Which overload these values fit. The checker refused any pair a call could not tell
    /// apart, so the first that fits is the only one that can — this is never choosing a
    /// best match, only finding the one.
    /// </summary>
    /// <summary>
    /// Which declaration each overloaded call resolved to, handed over by the checker.
    ///
    /// The interpreter used to choose again from the values it was holding, and the two
    /// rules disagreed: a call checked as returning String could evaluate to an Int. It
    /// is not a matter of the matcher being incomplete either -- an empty list carries no
    /// element type at run time, so the checker's answer cannot be reconstructed here even
    /// in principle. The program was type-checked against the checker's choice, so the
    /// checker's choice is the one that runs.
    /// </summary>
    public Dictionary<Expr.Call, Stmt.FuncDecl> ChosenOverload { get; set; } = [];

    /// <summary>
    /// The call being dispatched. Set once its arguments are evaluated, so a nested call
    /// in an argument position has finished with it before this one needs it.
    /// </summary>
    private Expr.Call? _call;

    /// <summary>
    /// The same question for a free function, whose runtime form is an EmFunction rather
    /// than a declaration. Matched by the body it holds, which is the declaration's own.
    /// </summary>
    internal EmFunction? PreselectedFunction(List<EmFunction> among) =>
        _call is not null && ChosenOverload.TryGetValue(_call, out var decl)
            ? among.FirstOrDefault(f => ReferenceEquals(f.Body, decl.Body))
            : null;

    /// <summary>What the checker picked for the call in hand, if it is one of these.</summary>
    private Stmt.FuncDecl? Preselected(List<Stmt.FuncDecl> among) =>
        _call is not null
        && ChosenOverload.TryGetValue(_call, out var decl)
        && among.Contains(decl)
            ? decl
            : null;

    private Stmt.FuncDecl? Choose(List<Stmt.FuncDecl> overloads, List<object?> args)
    {
        if (Preselected(overloads) is { } picked) return picked;
        if (overloads.Count == 1) return overloads[0];

        foreach (var candidate in overloads)
        {
            int least = candidate.Params.TakeWhile(p => p.Default is null).Count();
            if (args.Count < least || args.Count > candidate.Params.Count) continue;

            bool fits = true;
            for (int i = 0; i < args.Count; i++)
                if (candidate.Params[i].Type is { } declared && !Matches(declared, args[i]))
                { fits = false; break; }

            if (fits) return candidate;
        }

        return null;
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

        // Only names declared in *this* batch are gathered together. Without that, a
        // function redefined at a prompt would be read as an overload of the one it was
        // meant to replace — and correcting a typo would be impossible.
        HashSet<string> declaredHere = [];

        foreach (var stmt in program)
        {
            if (stmt is not Stmt.FuncDecl fn) continue;
            var built = new EmFunction(fn.Name.Lexeme, fn.Params, fn.Body, _globals);

            if (sets.TryGetValue(fn.Name.Lexeme, out var set)) { set.Add(built); continue; }

            if (declaredHere.Contains(fn.Name.Lexeme)
                && _globals.TryGet(fn.Name.Lexeme, out object? already)
                && already is EmFunction first)
            {
                var combined = new EmOverloads(fn.Name.Lexeme);
                combined.Add(first);
                combined.Add(built);
                sets[fn.Name.Lexeme] = combined;
                _globals.Declare(fn.Name.Lexeme, combined);
                continue;
            }

            declaredHere.Add(fn.Name.Lexeme);
            _globals.Declare(fn.Name.Lexeme, built);
        }
    }

    /// <summary>
    /// Builds every top-level type, a base and its traits before whatever uses them.
    ///
    /// Declaration order cannot decide this. A project is every <c>.em</c> file in the
    /// folder (§3.3), loaded in name order, so <c>class Dog with Swimmer</c> in dog.em ran
    /// before swimmer.em existed and failed with "No trait named Swimmer" — a program
    /// broken by what its files were called. The checker had the same fault from the same
    /// cause and reported the trait as a class.
    ///
    /// The checker has already refused cycles and unknown names, so following the
    /// dependencies here terminates and anything still missing is not this pass's to
    /// report — it is left to <see cref="BuildClass"/>, which says so properly.
    /// </summary>
    private void DeclareTypes(List<Stmt> program)
    {
        // An enum has no base and no traits, so it needs no ordering — but it is a type,
        // and leaving it out meant `emerald test` could not see one at all.
        foreach (var stmt in program)
            if (stmt is Stmt.EnumDecl e) Execute(e, _globals);

        Dictionary<string, Stmt.ClassDecl> declared = [];
        foreach (var stmt in program)
            if (stmt is Stmt.ClassDecl c) declared.TryAdd(c.Name.Lexeme, c);

        HashSet<string> done = [];

        void Build(Stmt.ClassDecl decl)
        {
            if (!done.Add(decl.Name.Lexeme)) return;

            foreach (var dependency in decl.Traits.Append(decl.BaseName!).Where(t => t is not null))
                if (declared.TryGetValue(dependency.Lexeme, out var earlier)) Build(earlier);

            _globals.Declare(decl.Name.Lexeme, BuildClass(decl, _globals));
        }

        foreach (var stmt in program)
            if (stmt is Stmt.ClassDecl c) Build(c);
    }

    /// <summary>
    /// Runs statements at a prompt, printing what a bare expression came to.
    ///
    /// The difference from <see cref="Run"/> is only that: an expression statement in a
    /// program computes something and discards it, which §3.1 calls an error, while at a
    /// prompt it is the question being asked.
    /// </summary>
    public void RunInteractive(List<Stmt> entry)
    {
        DeclareFunctions(entry);
        DeclareTypes(entry);

        foreach (var stmt in entry)
        {
            if (stmt is Stmt.FuncDecl or Stmt.ClassDecl) continue;

            if (stmt is Stmt.ExprStmt shown)
            {
                object? value = Evaluate(shown.Expression, _globals);

                if (value is not null) Console.WriteLine(Builtins.Display(value));
                continue;
            }

            Execute(stmt, _globals);
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

            case Stmt.PairDecl pd:
            {
                _line = pd.First.Line;
                if (Evaluate(pd.Init, env) is not EmPair pair)
                    throw new RuntimeError(
                        "Two names need a pair to take apart.",
                        "Pair(a, b) makes one, and so do a dictionary's find and to_list.");

                env.Declare(pd.First.Lexeme, pair.First);
                env.Declare(pd.Second.Lexeme, pair.Second);
                break;
            }

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
            {
                _line = t.Keyword.Line;
                var raised = AsError(Evaluate(t.Value, env));

                // Stamped here rather than left for the unwinding to fill in. Building the
                // error runs a constructor -- Error's own lives in the prelude -- and that
                // moves the interpreter's idea of the current line into a file the
                // programmer has never seen. An uncaught throw reported a prelude line
                // number against their own file name.
                throw new ThrownError(raised) { Line = t.Keyword.Line };
            }

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

        // A module's own state, named without its type (§3.3). Anything in scope wins, so
        // this is consulted only when nothing else has the name.
        bool inScope = env.TryGet(target.Name.Lexeme, out object? held);
        var module = inScope ? null : ModuleHolding(target.Name.Lexeme, env);

        if (a.Op.Type != TokenType.Assign)
        {
            if (!inScope && module is null) throw Unknown(target.Name);
            value = Operate(inScope ? held : module!.Statics[target.Name.Lexeme],
                            CompoundOp(a.Op.Type), value, a.Op);
        }

        if (module is not null) module.Statics[target.Name.Lexeme] = value;
        else if (!env.TryAssign(target.Name.Lexeme, value)) throw Unknown(target.Name);
    }

    /// <summary>
    /// The module a bare name belongs to, when what is running is inside one. Null in every
    /// other scope, which is every scope but a module's own members.
    /// </summary>
    private static EmClass? ModuleHolding(string name, Env env) =>
        env.TryGet("Self", out object? self) && self is EmClass module && module.IsModule
            ? module.OwnerOfStatic(name)
            : null;

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
            var setAt = Choose(instance.Class.FindMethods(Prelude.SetAtMethod), [position, value])
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
    /// Evaluates and discards. A bare name is never a call — <c>exit</c> had been made to
    /// mean <c>exit()</c> while parens were optional, and that went with them (§3.1). The
    /// checker rejects a statement whose value is thrown away, so nothing arrives here
    /// silently doing nothing; what reaches this is a call, an assignment, or a REPL line.
    /// </summary>
    private void ExecuteExpressionStatement(Stmt.ExprStmt statement, Env env) =>
        Evaluate(statement.Expression, env);

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

            throw new ThrownError(NewError(
                $"Assertion failed:  {Source.Of(statement.Condition)}"
                + $"\n    left  was {Builtins.Display(left)}"
                + $"\n    right was {Builtins.Display(right)}"))
            { Line = statement.Keyword.Line, FromAssertion = true };
        }

        if (Truthy(Evaluate(statement.Condition, env))) return;

        throw new ThrownError(
            NewError($"Assertion failed:  {Source.Of(statement.Condition)}"))
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

            // A dictionary is walkable only in the two-name form. §3.7 kept it out of the
            // loop because `for k in ages` cannot say whether k is a key or a pair, and
            // guessing is worse than refusing -- but `for (k, v) in ages` says so out
            // loud, so the objection does not apply to it.
            EmDict dict when f.Second is not null
                => dict.Keys.ToList().Select(k => (object?)new EmPair(k, dict.Get(k))),

            _ => throw new RuntimeError(
                $"Cannot loop over {Builtins.TypeName(iterable)}.",
                iterable is EmDict
                    ? "A dictionary walks in pairs:  for (key, value) in ages { ... }"
                    : "Loop over a range (1..5), a list, a set, or a string."),
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

            if (f.Second is { } second)
            {
                if (item is not EmPair pair)
                    throw new RuntimeError(
                        $"Two names need a pair to fill them, and this is "
                        + $"{Builtins.TypeName(item)}.",
                        "Loop over pairs, or take one name:  "
                        + $"for {f.Variable.Lexeme} in ...");

                scope.Declare(f.Variable.Lexeme, pair.First);
                scope.Declare(second.Lexeme, pair.Second);
            }
            else scope.Declare(f.Variable.Lexeme, item);

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
    private EmInstance AsError(object? value) => value switch
    {
        EmInstance instance when instance.Class.Descends(Prelude.ErrorType) => instance,
        string message => NewError(message),
        _ => throw new RuntimeError(
            $"Cannot throw {Builtins.TypeName(value)}.",
            $"Throw a String, or a type that extends {Prelude.ErrorType}:  "
            + $"throw {Prelude.ErrorType}(\"...\")")
    };

    /// <summary>
    /// A plain <see cref="Prelude.ErrorType"/> holding a message. The class comes from the
    /// prelude like any other, so this is an ordinary construction — the interpreter only
    /// has to know where to find it, which the globals answer.
    /// </summary>
    public EmInstance NewError(string message)
    {
        if (!_globals.TryGet(Prelude.ErrorType, out object? found) || found is not EmClass cls)
            throw new RuntimeError($"The prelude did not supply {Prelude.ErrorType}.");

        return (EmInstance)Instantiate(cls, [message]);
    }

    /// <summary>
    /// Catches both a thrown Emerald error and the interpreter's own runtime failures, so
    /// a failed <c>to_int</c> can be handled rather than merely avoided. Deliberately does
    /// not catch <c>exit</c> or a <c>return</c> unwinding through — neither is a failure.
    ///
    /// The clauses are tried in the order they are written. A failure the compiler raised
    /// itself is a plain Error, so a typed clause naming a program's own class correctly
    /// declines it and a bare clause still takes it.
    /// </summary>
    private void ExecuteTryCatch(Stmt.TryCatch node, Env env)
    {
        EmInstance caught;

        // Kept so a clause that declines the error can hand on exactly what arrived. A
        // rethrow that loses the line reports the prelude's, because building the
        // replacement runs a constructor there.
        int line;
        bool fromAssertion = false;

        try
        {
            ExecuteBlock(node.Body, new Env(env));
            return;
        }
        catch (ThrownError thrown)
        {
            caught = thrown.Value;
            line = thrown.Line;
            fromAssertion = thrown.FromAssertion;
        }
        catch (RuntimeError failure)
        {
            caught = NewError(failure.Message);
            line = failure.Line;
        }

        foreach (var clause in node.Clauses)
        {
            if (clause.Type is not null
                && !caught.Class.Descends(clause.Type.Name.Lexeme)) continue;

            var handler = new Env(env);
            handler.Declare(clause.Name.Lexeme, caught);
            ExecuteBlock(clause.Body, handler);
            return;
        }

        // Every clause named an error this is not. It keeps travelling, which is what a
        // try that does not handle something has to mean.
        throw new ThrownError(caught) { Line = line, FromAssertion = fromAssertion };
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
        Dictionary<string, List<Stmt.FuncDecl>> methods = [];
        List<string> required = [];

        void Provide(string name, Stmt.FuncDecl method)
        {
            if (!methods.TryGetValue(name, out var overloads))
                methods[name] = overloads = [];
            overloads.Add(method);
        }

        HashSet<string> traitNames = [];

        foreach (var traitName in decl.Traits)
        {
            if (!env.TryGet(traitName.Lexeme, out object? found) || found is not EmClass trait)
                throw new RuntimeError($"No trait named {traitName.Lexeme}.");

            foreach (var (name, provided) in trait.Methods)
                foreach (var method in provided)
                    if (method.Body is not null) Provide(name, method);
                    else required.Add(name);

            required.AddRange(trait.Unimplemented);

            // A trait built on another trait counts as both, so `x is Drawable` answers
            // yes for a class that reached it through a third. Collected here, where the
            // trait object is in hand, rather than walked at test time from names alone.
            traitNames.Add(traitName.Lexeme);
            traitNames.UnionWith(trait.TraitNames);
        }

        // What the traits gave, before the class's own methods take their places — kept so
        // an override can still reach the default it replaced.
        Dictionary<string, List<Stmt.FuncDecl>> fromTraits = new(methods);

        // A class's own methods replace what a trait provided under that name, rather than
        // joining it — otherwise mixing in a trait would silently overload every method
        // you wrote to replace one of its defaults.
        foreach (var name in decl.Members.OfType<Stmt.FuncDecl>()
                                 .Where(m => !m.IsStatic && m.Body is not null)
                                 .Select(m => m.Name.Lexeme)
                                 .Distinct())
            methods.Remove(name);

        foreach (var method in decl.Members.OfType<Stmt.FuncDecl>().Where(m => !m.IsStatic))
        {
            if (method.Body is not null) Provide(method.Name.Lexeme, method);
            else required.Add(method.Name.Lexeme);
        }

        // Anything the base already provides counts as implemented.
        List<string> unimplemented = [..
            required.Distinct()
                    .Where(n => !methods.ContainsKey(n) && super?.FindMethod(n)?.Body is null)];

        var built = new EmClass(decl.Name.Lexeme, decl.Kind, super, fields, methods,
                                constructor, unimplemented, env)
        { IsModule = decl.IsModule };

        foreach (var (name, provided) in fromTraits) built.FromTraits[name] = provided;
        built.TraitNames.UnionWith(traitNames);

        foreach (var property in decl.Members.OfType<Stmt.VarDecl>().Where(f => f.Getter is not null))
            built.Properties[property.Name.Lexeme] = property;

        foreach (var method in decl.Members.OfType<Stmt.FuncDecl>().Where(m => m.IsStatic))
        {
            if (!built.StaticMethods.TryGetValue(method.Name.Lexeme, out var overloads))
                built.StaticMethods[method.Name.Lexeme] = overloads = [];
            overloads.Add(method);
        }

        // Static initializers run once, when the type is declared.
        var staticScope = new Env(env);
        staticScope.Declare("Self", built);
        foreach (var field in decl.Members.OfType<Stmt.VarDecl>().Where(f => f.IsStatic))
            built.Statics[field.Name.Lexeme] =
                field.Init is null ? null : Evaluate(field.Init, staticScope);

        if (decl.Initializer is { Count: > 0 }) built.Initializer = decl.Initializer;

        return built;
    }

    /// <summary>
    /// An enum is an EmClass whose statics are its values, so <c>Color.RED</c> resolves
    /// through the same static lookup a class uses and nothing downstream needs to know
    /// the difference. <c>values</c> is added alongside, because asking an enum for its
    /// members is the one thing you cannot write yourself.
    /// </summary>
    private static EmClass BuildEnum(Stmt.EnumDecl decl, Env env)
    {
        Dictionary<string, List<Stmt.FuncDecl>> methods = [];

        foreach (var method in (decl.Methods ?? []).OfType<Stmt.FuncDecl>().Where(m => !m.IsStatic))
        {
            if (!methods.TryGetValue(method.Name.Lexeme, out var overloads))
                methods[method.Name.Lexeme] = overloads = [];
            overloads.Add(method);
        }

        var built = new EmClass(decl.Name.Lexeme, TypeKind.Enum, null, [], methods, null, [], env);

        foreach (var method in (decl.Methods ?? []).OfType<Stmt.FuncDecl>().Where(m => m.IsStatic))
        {
            if (!built.StaticMethods.TryGetValue(method.Name.Lexeme, out var overloads))
                built.StaticMethods[method.Name.Lexeme] = overloads = [];
            overloads.Add(method);
        }

        for (int i = 0; i < decl.Members.Count; i++)
            built.Statics[decl.Members[i].Lexeme] =
                new EmEnumValue(decl.Name.Lexeme, decl.Members[i].Lexeme, i) { Owner = built };

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

        // Field initializers run in a scope where `self` already exists, so one field can
        // be defined in terms of another.
        var fieldScope = new Env(cls.Closure);
        fieldScope.Declare("self", instance);
        foreach (var field in cls.AllFields())
            instance.Fields[field.Name.Lexeme] =
                field.Init is null ? null : Evaluate(field.Init, fieldScope);

        if (cls.ConstructorOwner is { } owner)
        {
            RunConstructor(owner, instance, args);
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

    /// <summary>
    /// Runs one class's constructor on an object. <paramref name="owner"/> is the class
    /// that declares it rather than the object's own class, because the chain walks
    /// upward: <c>super(...)</c> calls back in here with the class above.
    ///
    /// A base constructor taking no required arguments is called implicitly, so a
    /// hierarchy whose base has nothing to fill stays quiet (§3.2). One that needs
    /// arguments is the caller's to write, and the checker insists on it.
    /// </summary>
    public void RunConstructor(EmClass owner, EmInstance instance, List<object?> args)
    {
        var constructor = owner.OwnConstructor!;

        var scope = new Env(owner.Closure);
        scope.Declare("self", instance);
        scope.Declare("super", new EmSuper(instance, owner));

        BindParameters(constructor.Params, args, scope, owner.Name);

        // The implicit call, before the body. Skipped when the body opens with an explicit
        // one, which would otherwise run the base twice.
        if (owner.Super?.ConstructorOwner is { } above && !OpensWithSuper(constructor.Body))
            RunConstructor(above, instance, []);

        try { ExecuteBlock(constructor.Body, scope); }
        catch (ReturnSignal) { /* an early return from a constructor is allowed */ }
    }

    /// <summary>Whether a constructor body's first statement is <c>super(...)</c>.</summary>
    public static bool OpensWithSuper(List<Stmt> body) =>
        body.Count > 0
        && body[0] is Stmt.ExprStmt
           { Expression: Expr.Call { Callee: Expr.Variable { Name.Lexeme: "super" } } };

    public object? CallMethod(
        Stmt.FuncDecl method, EmInstance receiver, Env closure, List<object?> args)
    {
        var scope = new Env(closure);
        scope.Declare("self", receiver);

        // `super` is bound the way `self` is — an ordinary name, not a keyword — and points
        // at what the class declaring this method inherits, so an override can call the
        // thing it replaced instead of calling itself forever.
        if (receiver.Class.OwnerOfMethod(method) is { } declaring)
            scope.Declare("super", new EmSuper(receiver, declaring));

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
    /// Field, then property, then method. Whether the method is <em>run</em> is decided by
    /// the caller, not here: <c>dog.speak</c> hands back a <see cref="BoundMethod"/> and
    /// <c>dog.speak()</c> runs it (§3.1). Only a written '(' or a trailing block makes a
    /// Call node, so <paramref name="invoking"/> is the parentheses, carried down.
    /// </summary>
    private object? GetOrInvoke(
        EmInstance instance, Token name, List<object?> args, bool invoking = true)
    {
        // Every value answers this, and an instance reaches it here rather than through
        // Builtins, which only ever sees the native ones. Answered before the class's own
        // members are consulted: the point of the name is that it means one thing on
        // everything, so a class is not allowed to redefine it -- the checker says so at
        // the declaration, and this is the runtime half of the same rule.
        if (name.Lexeme == "type_name" && args.Count == 0)
            return invoking
                ? Builtins.TypeName(instance)
                : throw new RuntimeError(
                    "type_name is a method. Call it:  value.type_name()");

        // .or and .must belong to the ?, not to the value, so a value that is there simply
        // is itself — the same answer an Int or a String gives. An instance is the only
        // value that could declare these names itself, which is why the checker reserves
        // them: otherwise whether .or meant the fallback or a method would depend on what
        // the variable happened to be holding at the time.
        if (name.Lexeme is "or" or "must") return instance;

        if (!invoking && instance.Fields.TryGetValue(name.Lexeme, out object? value))
            return value;

        // A property is a var with a body: reading it runs the getter (§3.2). Callers
        // cannot tell it apart from a stored field, which is still the whole point — that
        // interchange is where uniform access lives now that a method is not part of it.
        if (instance.Class.FindProperty(name.Lexeme) is { Getter: { } getter })
        {
            if (invoking)
                throw new RuntimeError(
                    $"{instance.Class.Name}.{name.Lexeme} is a property, not a method.",
                    $"A property is read without parentheses:  {Lower(instance.Class.Name)}.{name.Lexeme}");

            var scope = new Env(instance.Class.Closure);
            scope.Declare("self", instance);
            try { ExecuteBlock(getter, scope); }
            catch (ReturnSignal r) { return r.Value; }
            return null;
        }

        var overloads = instance.Class.FindMethods(name.Lexeme);
        if (overloads.Count > 0)
        {
            // No parentheses: the method itself, receiver already attached. Which overload
            // is meant cannot be read off the call site, so the checker resolves it against
            // the expected func(...) type and this is only the backstop.
            if (!invoking)
                return overloads.Count == 1
                    ? new BoundMethod(overloads[0], instance, instance.Class.Closure)
                    : new BoundOverloads(overloads, instance, instance.Class.Closure);

            var method = Choose(overloads, args)
                ?? throw new RuntimeError(
                    $"No version of {instance.Class.Name}.{name.Lexeme} takes these arguments.");

            return CallMethod(method, instance, instance.Class.Closure, args);
        }

        // A field holding a function, reached with parentheses. EvaluateCall handles the
        // common shape; this catches the rest, so `holder.cb()` is never a silent no-op.
        if (invoking && instance.Fields.TryGetValue(name.Lexeme, out object? held))
        {
            if (held is ICallable fn) return fn.Call(this, args);

            throw new RuntimeError(
                $"{instance.Class.Name}.{name.Lexeme} is a field, not a method.",
                $"A field is read without parentheses:  {Lower(instance.Class.Name)}.{name.Lexeme}");
        }

        throw new RuntimeError(
            $"No member named {name.Lexeme} on {instance.Class.Name}.");
    }

    /// <summary>A class name as an example receiver, so a hint reads like written code.</summary>
    private static string Lower(string className) =>
        className.Length == 0 ? "it" : char.ToLowerInvariant(className[0]) + className[1..];

    /// <summary>
    /// Runs a module's top-level code, once, before its first member is reached (§3.3).
    ///
    /// The flag is set before the body runs, not after: a module whose initializer reaches
    /// back into itself would otherwise recurse forever, and running it once is the promise
    /// — not running it once per path that arrives.
    /// </summary>
    private void Initialize(EmClass cls)
    {
        if (cls.Initialized || cls.Initializer is not { } body) return;

        cls.Initialized = true;

        var scope = new Env(cls.Closure, shared: cls.Statics);
        scope.Declare("Self", cls);
        ExecuteBlock(body, scope);
    }

    /// <summary>
    /// <c>super.speak()</c> — runs what this class replaced, on this same instance. The
    /// method is looked up above the class that declared the running one, and then called
    /// with the real receiver, so anything it calls in turn dispatches normally.
    /// </summary>
    private object? InvokeInherited(EmSuper above, Token name, List<object?> args)
    {
        var overloads = above.DeclaredIn.Inherited(name.Lexeme);

        if (overloads.Count == 0)
            throw new RuntimeError(
                $"Nothing above {above.DeclaredIn.Name} has a {name.Lexeme}.",
                $"super reaches what {above.DeclaredIn.Name} replaced. There is no "
                + $"{name.Lexeme} to replace.");

        var method = Choose(overloads, args)
            ?? throw new RuntimeError(
                $"No version of super.{name.Lexeme} takes these arguments.");

        return CallMethod(method, above.Instance, above.Instance.Class.Closure, args);
    }

    /// <summary>Type-level access: <c>Dog.from_shelter_id(42)</c>, <c>Vector3.zero</c>.</summary>
    private object? GetStatic(
        EmClass cls, Token name, List<object?> args, bool invoking = true)
    {
        Initialize(cls);

        // A static var is a value, so it is read without parentheses either way — the
        // parens only decide what happens to a static *method* (§3.1).
        if (!invoking && cls.OwnerOfStatic(name.Lexeme) is { } owner)
            return owner.Statics[name.Lexeme];

        if (cls.FindStaticMethods(name.Lexeme) is { Count: > 0 } statics)
        {
            if (!invoking)
            {
                if (statics.Count > 1)
                    throw new RuntimeError(
                        $"{cls.Name}.{name.Lexeme} has {statics.Count} versions, "
                        + "so it is not clear which one this names.");

                return new StaticMethod(statics[0], cls);
            }

            var method = Choose(statics, args)
                ?? throw new RuntimeError(
                    $"No version of {cls.Name}.{name.Lexeme} takes these arguments.");

            return CallStatic(method, cls, args);
        }

        if (invoking && cls.OwnerOfStatic(name.Lexeme) is { } holder)
        {
            if (holder.Statics[name.Lexeme] is ICallable fn) return fn.Call(this, args);

            throw new RuntimeError(
                $"{cls.Name}.{name.Lexeme} is a value, not a method.",
                $"It is read without parentheses:  {cls.Name}.{name.Lexeme}");
        }

        throw new RuntimeError(
            $"No class member named {name.Lexeme} on {cls.Name}.",
            cls.FindMethod(name.Lexeme) is not null
                ? $"{name.Lexeme} belongs to an instance — call it on a {cls.Name} value."
                : null);
    }

    /// <summary>
    /// Runs whichever version of an overloaded method the arguments fit. Public for
    /// <see cref="BoundOverloads"/>, which holds the set until the call supplies them.
    /// </summary>
    public object? CallOverload(
        List<Stmt.FuncDecl> alternatives, EmInstance receiver, Env closure, List<object?> args)
    {
        var method = Choose(alternatives, args)
            ?? throw new RuntimeError(
                $"No version of {alternatives[0].Name.Lexeme} takes these arguments.");

        return CallMethod(method, receiver, closure, args);
    }

    /// <summary>
    /// Runs a static method. Public because <see cref="StaticMethod"/> holds one as a
    /// value and calls back in, the same way <see cref="BoundMethod"/> does.
    /// </summary>
    /// <summary>
    /// A method on an enum value. Like a static call with <c>self</c> bound: an enum has no
    /// fields, so the value and the parameters are the whole of what the body can reach.
    /// </summary>
    public object? CallEnumMethod(
        Stmt.FuncDecl method, EmEnumValue value, EmClass owner, List<object?> args)
    {
        var scope = new Env(owner.Closure);
        scope.Declare("self", value);
        scope.Declare("Self", owner);
        BindParameters(method.Params, args, scope, method.Name.Lexeme);

        try { ExecuteBlock(method.Body!, scope); }
        catch (ReturnSignal r) { return r.Value; }
        return null;
    }

    public object? CallStatic(Stmt.FuncDecl method, EmClass owner, List<object?> args)
    {
        var scope = new Env(owner.Closure);
        scope.Declare("Self", owner);
        BindParameters(method.Params, args, scope, method.Name.Lexeme);

        try { ExecuteBlock(method.Body!, scope); }
        catch (ReturnSignal r) { return r.Value; }
        return null;
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
        Expr.TypeTest t => EvaluateTypeTest(t, env),
        Expr.TypeCast t => EvaluateTypeCast(t, env),
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
        if (env.TryGet(name.Lexeme, out object? value)) return value;

        // Inside a module, its own members answer to their bare names (§3.3). A module is
        // a class with no instances, so a static method's `Self` is the module itself and
        // its statics are what a sibling name means.
        if (env.TryGet("Self", out object? holder) && holder is EmClass module
            && module.IsModule
            && (module.OwnerOfStatic(name.Lexeme) is not null
                || module.FindStaticMethod(name.Lexeme) is not null))
            return GetStatic(module, name, [], invoking: false);

        throw Unknown(name);
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
            var at = Choose(instance.Class.FindMethods(Prelude.AtMethod), [position])
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

    /// <summary>
    /// <c>value is Dog</c> at runtime. Walks the class chain and the traits, so a test
    /// against a base or a trait answers true for anything below it — which is what makes
    /// the check worth having rather than a comparison against one exact name.
    ///
    /// <c>nothing is Dog</c> is false rather than an error. The value that might be
    /// missing is the ordinary receiver here, and answering the question is more use than
    /// refusing it.
    /// </summary>
    private object EvaluateTypeTest(Expr.TypeTest t, Env env)
    {
        object? value = Evaluate(t.Value, env);
        string wanted = t.Type.Name.Lexeme;

        return value is EmInstance instance && Reaches(instance.Class, wanted);
    }

    /// <summary>
    /// <c>animal as Dog</c>. The value when it really is one, and nothing when it is not
    /// — never a failure, because a cast that might miss is exactly what <c>T?</c> is for.
    /// </summary>
    private object? EvaluateTypeCast(Expr.TypeCast cast, Env env)
    {
        _line = cast.Keyword.Line;
        object? value = Evaluate(cast.Value, env);

        return value is EmInstance instance && Reaches(instance.Class, cast.Type.Name.Lexeme)
            ? value
            : null;
    }

    /// <summary>
    /// Whether a class answers to a name, through its bases or the traits mixed into any
    /// of them. Shared by <c>is</c> and <c>as</c>, so the two can never disagree about
    /// what a value is -- which they would, sooner or later, as two copies of a walk.
    /// </summary>
    private static bool Reaches(EmClass? cls, string wanted)
    {
        for (var walk = cls; walk is not null; walk = walk.Super)
            if (walk.Name == wanted || walk.TraitNames.Contains(wanted)) return true;

        return false;
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
    /// (§3.2). Everything else falls through to the built-in numeric behavior.
    ///
    /// This has to be an instance method — calling a user's <c>add</c> needs the
    /// interpreter — which is why <see cref="Arithmetic"/> stays static behind it.
    /// </summary>
    private object? Operate(object? left, TokenType op, object? right, Token token)
    {
        if (left is not EmInstance instance || !Prelude.Operators.TryGetValue(op, out var entry))
            return Arithmetic(left, op, right, token);

        var method = Choose(instance.Class.FindMethods(entry.Method), [right]);
        if (method is null && instance.Class.FindMethods(entry.Method).Count > 0)
            throw new RuntimeError(
                $"No version of {instance.Class.Name}.{entry.Method} takes "
                + $"{Builtins.TypeName(right)}.",
                $"{token.Lexeme} passes the right-hand value to {entry.Method}.");

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
    public bool Same(object? left, object? right)
    {
        if (left is EmInstance instance
            && Choose(instance.Class.FindMethods(Prelude.EqualsMethod), [right]) is { } method)
            return Truthy(CallMethod(method, instance, instance.Class.Closure, [right]));

        // A struct is a value (§3.2), so two of them holding the same things are the same
        // thing — which is what "value type" means, and what C# gives a struct for free.
        // Without this, `Point(1, 2) == Point(1, 2)` was false: a wrong answer, silently,
        // to the most obvious question anyone asks of a small value.
        //
        // Fields are compared with this same method, so a struct holding a struct compares
        // by value all the way down, and one holding a class compares that field by
        // identity — which is what == means for a class, consistently.
        if (left is EmInstance a && right is EmInstance b
            && a.Class.Kind == TypeKind.Struct && a.Class == b.Class)
            return a.Fields.Count == b.Fields.Count
                   && a.Fields.All(f => b.Fields.TryGetValue(f.Key, out var theirs)
                                        && Same(f.Value, theirs));

        // A container is a value in the same sense a struct is, so two holding the same
        // things are the same thing. Without this `[1, 2] == [1, 2]` was false, and
        // §3.7's promise that list search uses == made that answer spread: a list of
        // lists could not find a list it visibly contained.
        //
        // Safe here in a way it is not everywhere, because these are mutable: the classic
        // hazard is a container used as a key and then changed underneath the hash, and
        // §3.7 already restricts keys and set members to Int, Float, String and Bool. The
        // hazard is structurally out of reach rather than merely unlikely.
        if (left is EmList first && right is EmList second)
            return first.Items.Count == second.Items.Count
                   && first.Items.Zip(second.Items).All(p => Same(p.First, p.Second));

        if (left is EmSet leftSet && right is EmSet rightSet)
            return leftSet.Members.Count == rightSet.Members.Count
                   && leftSet.Members.All(m => rightSet.Members.Any(o => Same(m, o)));

        // Order is not part of what a dictionary *is*, even though §3.7 keeps it: two
        // dictionaries with the same pairs answer every question the same way.
        if (left is EmDict leftDict && right is EmDict rightDict)
            return leftDict.Keys.Count == rightDict.Keys.Count
                   && leftDict.Keys.All(k => rightDict.Has(k)
                                             && Same(leftDict.Get(k), rightDict.Get(k)));

        // A pair is two values travelling together, so two holding the same two are the
        // same pair. Missed when Pair was built: it fell through to host equality, and a
        // pair of structs was unequal to an identical pair even though the structs
        // themselves compared equal. The general lesson is worth more than the fix -- a
        // new composite type has to be added to every shared operation, not only to the
        // ones its own tests exercise.
        if (left is EmPair leftPair && right is EmPair rightPair)
            return Same(leftPair.First, rightPair.First)
                   && Same(leftPair.Second, rightPair.Second);

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
            var method = Choose(instance.Class.FindMethods(Prelude.CompareMethod), [right])
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

        // ?. stops here when there is nothing to read. Each link checks itself, and that is
        // enough for the whole chain: a ?. hands back a T?, so the checker requires ?. at
        // every step after it — there is no way to write a chain that runs on past a
        // missing value, which is the rule other languages need an end-of-chain rule for.
        if (target is null && g.Optional) return null;

        if (target is EmSuper above) return InvokeInherited(above, g.Name, []);
        if (target is EmInstance instance)
            return GetOrInvoke(instance, g.Name, [], invoking: false);
        if (target is EmClass cls) return GetStatic(cls, g.Name, [], invoking: false);

        // An enum value carries a name and nothing else, so that name is the one property
        // in the built-in surface — it is data the value has, not work it does. Its
        // .to_string() is the method beside it, and takes parentheses like any other.
        if (target is EmEnumValue enumValue && g.Name.Lexeme == "name") return enumValue.Name;

        // Otherwise the built-ins expose no properties (§3.1), so every member of one is a
        // method — and naming a method without parentheses is the method itself, on a
        // built-in exactly as on anything else. The checker has already refused a name
        // that is not one, and refused the block-taking methods whose type needs a block.
        return new BuiltinMethod(target, g.Name.Lexeme);
    }

    private object? EvaluateCall(Expr.Call c, Env env)
    {
        // Pair(a, b). Answered before the callee is looked up, since there is no value
        // named Pair to find -- the same shape super(...) uses. A program that declares
        // its own Pair wins, so this cannot take a name out of anyone's hands.
        if (c.Callee is Expr.Variable { Name.Lexeme: "Pair" } && c.Args.Count == 2
            && !env.TryGet("Pair", out _))
            return new EmPair(Evaluate(c.Args[0], env), Evaluate(c.Args[1], env));

        // A method call is a Get in callee position — evaluate the receiver, then dispatch.
        if (c.Callee is Expr.Get get)
        {
            // Set before the receiver is evaluated, not after: this is the line a failure
            // inside the call belongs to. Only EvaluateGet used to do it, so a receiver
            // that was a variable set the line on its way past and a literal one did not —
            // `print("banana".to_int())` reported main.em:0, whatever line it sat on.
            _line = get.Name.Line;

            object? target = Evaluate(get.Target, env);

            // The receiver is evaluated before the arguments so that a ?. on nothing skips
            // them too: `logger?.write(expensive())` should not do the work for a call it
            // is not going to make.
            if (target is null && get.Optional) return null;

            // .or is an intrinsic, not a method (§3.2), and its whole meaning is "the value
            // to use when there is none" — so the fallback is evaluated only when there is
            // none. It read as a call and behaved like one: `here.or(fallback())` ran the
            // fallback and discarded it, burning whatever side effects it had. Every
            // neighboring construct short-circuits, including the `or` operator this
            // shares a name with, and §3.2 defines this one as `if v != nothing then v
            // else x` — which evaluates a single branch.
            if (get.Name.Lexeme == "or" && c.Args.Count == 1 && c.Trailing is null)
                return target ?? Evaluate(c.Args[0], env);

            List<object?> received = [.. c.Args.Select(a => Evaluate(a, env))];
            if (c.Trailing is not null) received.Add(new EmLambda(c.Trailing, env));
            _call = c;

            // A field holding a function: `button.on_click()` calls what it holds, where
            // `button.on_click` on its own is the function itself. Only a written '(' or a
            // trailing block makes a Call node, so this is the one place that can tell the
            // two apart — GetOrInvoke sees no parentheses and handed the field straight
            // back, which made every callback in a field a silent no-op.
            if (target is EmInstance holder
                && holder.Fields.TryGetValue(get.Name.Lexeme, out object? held)
                && held is ICallable stored
                && holder.Class.FindMethods(get.Name.Lexeme).Count == 0)
                return stored.Call(this, received);

            if (target is EmSuper above) return InvokeInherited(above, get.Name, received);
            if (target is EmInstance instance) return GetOrInvoke(instance, get.Name, received);
            if (target is EmClass cls) return GetStatic(cls, get.Name, received);

            // A method the enum declared. Checked before the built-in surface so a value
            // answers for itself, the way every other type does.
            if (target is EmEnumValue value
                && value.Owner?.FindMethod(get.Name.Lexeme) is { } declared)
                return CallEnumMethod(declared, value, value.Owner, received);

            return Builtins.InvokeMethod(this, target, get.Name.Lexeme, received);
        }

        List<object?> args = [.. c.Args.Select(a => Evaluate(a, env))];
        if (c.Trailing is not null) args.Add(new EmLambda(c.Trailing, env));

        object? callee = Evaluate(c.Callee, env);
        _call = c;
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
                // Checked, so an Int that will not hold the answer says so instead of
                // wrapping to a negative one. ** already reported overflow and these
                // three did not, which made the largest number in the language behave
                // one way under one operator and another way under the rest.
                case TokenType.Plus: return Checked(() => checked(a + b), a, "+", b);
                case TokenType.Minus: return Checked(() => checked(a - b), a, "-", b);
                case TokenType.Star: return Checked(() => checked(a * b), a, "*", b);
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

        double x = ToDouble(left), y = ToDouble(right);

        // A NaN does not sit anywhere on the number line, so all four questions answer no
        // -- including `nan <= nan`. CompareTo would instead give it a total order and
        // rank it below every number, which is what .NET needs for sorting and is not what
        // an operator should say. sort() still uses that total order, exactly as C# does.
        if (double.IsNaN(x) || double.IsNaN(y)) return false;

        int cmp = x.CompareTo(y);
        return op.Type switch
        {
            TokenType.Less => cmp < 0,
            TokenType.Greater => cmp > 0,
            TokenType.LessEqual => cmp <= 0,
            _ => cmp >= 0
        };
    }

    /// <summary>
    /// Sameness for everything without a rule of its own.
    ///
    /// NaN is the exception, and it is deliberate: .NET's <c>Equals</c> says two NaNs are
    /// the same value, while C#'s <c>==</c> says they are not, and Emerald had silently
    /// inherited the first. IEEE says a NaN is equal to nothing, itself included, and
    /// every language a reader is likely to arrive from agrees — so <c>x == x</c> being
    /// false is the surprise they have already been taught to expect, and its opposite is
    /// the one that would cost them.
    ///
    /// This reaches list search too, since §3.7 promises that uses ==. It does <em>not</em>
    /// reach a set or a dictionary key: those hash, and a hash table that disagreed with
    /// its own equality would lose values rather than merely answer oddly -- so a set
    /// holds one NaN, not two. That is the single place in the language where membership
    /// and == give different answers, and it is exactly where C# puts it, for the same
    /// reason: the hash contract does not survive a value that is not equal to itself.
    /// </summary>
    private static bool AreEqual(object? a, object? b) =>
        a is double x && double.IsNaN(x) || b is double y && double.IsNaN(y)
            ? false
            : a is null && b is null || (a?.Equals(b) ?? false);

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
        // A function-shaped annotation names no type, so the name switch below would
        // never reach it and every func(...) parameter matched no overload at all.
        if (declared.Function is not null) return value is ICallable;

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
            "Pair" => value is EmPair,
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
                + $"{baseValue}.to_float() ** {exponent}");
        }

        return result;
    }

    /// <summary>
    /// Runs an arithmetic operation that may not fit, and reports it if it does not.
    ///
    /// The alternative is what C#, Java, Go and Kotlin do — wrap silently, so adding one
    /// to the largest Int gives the smallest — and it is the worst shape of failure this
    /// language can produce: not a crash, which points at itself, but a plausible wrong
    /// number that goes on being used. Swift is the precedent for trapping instead, and
    /// <c>**</c> here had already made the same choice on its own.
    ///
    /// Floats are untouched: they overflow to infinity, which says so.
    /// </summary>
    private static object Checked(Func<long> operation, long left, string op, long right)
    {
        try
        {
            return operation();
        }
        catch (OverflowException)
        {
            throw new RuntimeError(
                $"{left} {op} {right} is too large to hold in an Int.",
                "An Int holds whole numbers from -9223372036854775808 to "
                + "9223372036854775807.\nFor arithmetic beyond that, work in Floats:  "
                + $"{left}.to_float() {op} {right}");
        }
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
            if (interpreter.PreselectedFunction(_alternatives) is { } picked)
                return picked.Call(interpreter, args);

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

    internal sealed class EmFunction(
        string name, List<Param> parameters, List<Stmt> body, Env closure) : ICallable
    {
        public List<Param> Parameters => parameters;

        /// <summary>
        /// The declaration's own statement list, by reference. An EmFunction does not hold
        /// its Stmt.FuncDecl, but it holds this, and no two declarations share one -- so it
        /// is what matches a runtime function to the declaration the checker picked.
        /// </summary>
        public List<Stmt> Body => body;

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
