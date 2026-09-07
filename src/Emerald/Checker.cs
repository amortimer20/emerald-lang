namespace Emerald;

/// <summary>
/// The static pass: walks the same tree the interpreter walks, but computes types
/// instead of values. This is where Emerald stops being a prototype with annotations
/// and starts being statically typed.
///
/// Notably it also catches things the interpreter could only find at runtime — unknown
/// variables, const reassignment, calling a method on a value that might be nothing.
/// </summary>
public sealed class Checker(
    string fileName,
    IReadOnlyDictionary<Stmt, string>? fileOf = null,
    Func<string, string[]>? sourceOf = null,
    bool interactive = false)
{
    public List<Diagnostic> Diagnostics { get; } = [];

    private sealed record Binding(EmType Type, bool IsConst, int Line);

    private sealed class Scope(Scope? parent = null, bool functionBoundary = false)
    {
        private readonly Dictionary<string, Binding> _names = [];

        public void Declare(string name, EmType type, bool isConst = false, int line = 0) =>
            _names[name] = new Binding(type, isConst, line);

        public Binding? Find(string name) =>
            _names.TryGetValue(name, out var b) ? b : parent?.Find(name);

        /// <summary>
        /// Looks only within the current function, for shadowing detection. C#'s rule:
        /// a local may not hide another local from an enclosing block, but crossing a
        /// function boundary is fine — so a local named <c>count</c> is legal even when
        /// a module-level <c>count</c> exists.
        /// </summary>
        public Binding? FindInFunction(string name)
        {
            if (_names.TryGetValue(name, out var b)) return b;
            return functionBoundary ? null : parent?.FindInFunction(name);
        }
    }

    /// <summary>Kernel functions are not arity-checked in v0 — <c>read_line</c> takes an
    /// optional prompt, and modelling that needs richer signatures than this has.</summary>
    /// <summary>
    /// The kernel, with real arities. These were once a bare return type and a single
    /// <c>Any</c> parameter that the call checker then skipped, on the grounds that a
    /// signature could not say <c>read_line</c>'s prompt was optional — which stopped
    /// being true when <see cref="EmType.Func"/> gained <c>Required</c>. Until then
    /// <c>random(1)</c> passed the checker and reached a .NET IndexOutOfRange.
    /// </summary>
    private static readonly Dictionary<string, EmType.Func> Kernel = new()
    {
        ["print"] = new([EmType.Any], EmType.Nothing, Required: 0),
        ["read_line"] = new([EmType.Any], EmType.String, Required: 0),
        ["random"] = new([EmType.Int, EmType.Int], EmType.Int, Required: 2),
        ["exit"] = new([EmType.Int], EmType.Nothing, Required: 0),
    };

    /// <summary>
    /// What the body being checked promised to return, and the name to call it in a
    /// diagnostic. This was a stack of <c>Any</c> used only to tell whether a return was
    /// inside a function at all, which is why a declared return type went unchecked.
    /// </summary>
    private readonly Stack<(string What, EmType Type)> _returnTypes = new();

    /// <summary>
    /// How many loops enclose the statement being checked. Reset across a function
    /// boundary, so `items.each { x => break }` is rejected: the block is a function, and
    /// break cannot leave one. Ruby allows it and the result is a control-flow construct
    /// whose behavior depends on whether the enclosing call happens to yield.
    /// </summary>
    private int _loopDepth;

    /// <summary>
    /// Loops enclosing this function from outside it. Lets the diagnostic tell apart
    /// "there is no loop here" from "the loop is out there, but a block is a function and
    /// break cannot leave one" — a distinction a student writing `items.each { x => break }`
    /// badly needs, because the loop is right there on the screen.
    /// </summary>
    private int _hiddenLoops;

    private readonly Dictionary<string, ClassInfo> _classes = [];

    /// <summary>
    /// Type declarations rejected as duplicates. They are still walked as statements, and
    /// without this each one is checked against the <em>winning</em> type of the same name —
    /// so a second `class Dog` reports that its constructor fails to assign the first
    /// Dog's fields. A cascade, which §3.6 forbids.
    /// </summary>
    private readonly HashSet<Stmt> _rejectedTypes = new(ReferenceEqualityComparer.Instance);

    /// <summary>Which type is being checked, and whether inside its constructor — the
    /// only place a struct may write its own fields.</summary>
    private ClassInfo? _currentType;
    private bool _inConstructor;

    /// <summary>
    /// Whether the constructor being checked calls <c>super(...)</c>. Read twice: to
    /// insist on the call when the base needs arguments, and to stop definite assignment
    /// asking this class for fields the base's constructor has just filled (§3.2).
    /// </summary>
    private bool _sawSuperCall;

    /// <summary>The file whose top-level statement is being checked, so a diagnostic in a
    /// project of many files names the right one.</summary>
    private string _file = fileName;

    public void Check(List<Stmt> program)
    {
        var globals = new Scope();
        foreach (var (name, signature) in Kernel)
            globals.Declare(name, signature);

        // Which variables a call can change behind a check's back. Gathered before
        // anything is checked, because a function declared below still reassigns a
        // variable used above it.
        FindCapturedAssignments(program);

        // Built-in modules are ordinary named types to the checker, so Math.sqrt resolves
        // through the same signature table as String.upper.
        foreach (var name in Builtins.Modules.Keys)
            globals.Declare(name, new EmType.Prim(name));

        // The kernel is reachable through its own name as well as bare (§3.3), which is
        // what stops it being the one namespace nobody can explore: everything else
        // answers a dot, and `print` answered nothing until Kernel existed to type.
        globals.Declare("Kernel", new EmType.Prim("Kernel"));

        // Classes are registered by name first, so they can reference each other in any
        // order — including a base declared below its subclass.
        //
        // A repeated type name is rejected for the same reason a repeated function name
        // is: the second declaration used to overwrite the first in silence, so every
        // reference quietly meant the later one. The operator traits make this reachable
        // without a second file — `trait Addable` in a program would otherwise replace the
        // built-in one and break `+` in ways that point nowhere near the cause.
        Dictionary<string, Stmt.ClassDecl> declaringType = [];
        foreach (var stmt in program)
        {
            if (stmt is not Stmt.ClassDecl c) continue;
            string name = c.Name.Lexeme;

            if (_classes.ContainsKey(name))
            {
                _file = fileOf?.GetValueOrDefault(stmt) ?? fileName;

                // A prelude trait has a line number, but it is a line in a file the
                // programmer has never seen, so pointing at it would be worse than useless.
                if (Prelude.TypeNames.Contains(name))
                    Error(c.Name.Line,
                          $"{name} is one of the built-in operator traits.",
                          "It is what gives a type its operator. Pick another name for this one.");
                else
                    Error(c.Name.Line,
                          $"{name} is already defined on line {declaringType[name].Name.Line}.",
                          "Each type name means one type. Rename one of them.");

                _rejectedTypes.Add(c);
                continue;
            }

            // Kind is set here rather than in DescribeClass, which runs a type at a time:
            // `class Dog with Swimmer` in dog.em was described before swimmer.em, read
            // Swimmer's kind while it was still the default, and reported the trait as a
            // class. Whether a name is a trait cannot depend on where its file sorts.
            _classes[name] = new ClassInfo(name) { Kind = c.Kind };
            declaringType[name] = c;
        }

        // An enum is a ClassInfo with a different Kind, so type annotations, Obj values
        // and Color.RED all resolve through the machinery classes already use. What it
        // is *not* allowed to do is enforced where those differences matter.
        foreach (var stmt in program)
        {
            if (stmt is not Stmt.EnumDecl e) continue;
            string name = e.Name.Lexeme;

            if (_classes.ContainsKey(name))
            {
                _file = fileOf?.GetValueOrDefault(stmt) ?? fileName;
                Error(e.Name.Line, $"{name} is already defined.",
                      "Each type name means one type. Rename one of them.");
                continue;
            }

            var info = new ClassInfo(name) { Kind = TypeKind.Enum };
            _classes[name] = info;

            foreach (var member in e.Members)
                info.StaticFields[member.Lexeme] = new EmType.Obj(info);

            // Asking an enum for its own members is the one thing a program cannot write
            // for itself, so it is supplied rather than left to be hand-maintained.
            info.StaticFields["values"] = new EmType.Lst(new EmType.Obj(info));
        }

        // Only the winning declaration describes its type. Letting a rejected duplicate
        // describe it too would merge two types' members into one.
        foreach (var stmt in program)
            if (stmt is Stmt.ClassDecl c && ReferenceEquals(declaringType[c.Name.Lexeme], c))
                DescribeClass(c);

        // An enum is a ClassInfo, so its methods are described the same way a class's are.
        foreach (var stmt in program)
            if (stmt is Stmt.EnumDecl e && _classes.TryGetValue(e.Name.Lexeme, out var enumInfo)
                && enumInfo.Kind == TypeKind.Enum)
                DescribeMembers(enumInfo, e.Name.Lexeme, e.Methods ?? []);

        // A class name in expression position is its constructor.
        foreach (var (name, info) in _classes)
            globals.Declare(name,
                            new EmType.Func(info.ConstructorParams, new EmType.Obj(info),
                                            info.ConstructorRequired));

        // Functions are visible before their declaration, so a file reads top to bottom
        // without forward-declaration ceremony.
        //
        // Several functions may share a name, distinguished by what they take (§3.2).
        // Overlap is rejected here rather than at the call: overlap is decidable — finite
        // arity, static types — so the error belongs to whoever wrote the second one, and
        // a call never has to resolve between two candidates that could both match.
        Dictionary<string, List<(EmType.Func Signature, int Line)>> overloads = [];

        foreach (var stmt in program)
        {
            if (stmt is not Stmt.FuncDecl fn) continue;

            var signature = SignatureOf(fn);
            if (!overloads.TryGetValue(fn.Name.Lexeme, out var existing))
                overloads[fn.Name.Lexeme] = existing = [];

            var clash = existing.FirstOrDefault(e => Indistinguishable(e.Signature, signature));
            if (clash.Signature is not null)
            {
                _file = fileOf?.GetValueOrDefault(stmt) ?? fileName;
                Error(fn.Name.Line,
                      $"{fn.Name.Lexeme} already has an overload matching this one, "
                      + $"on line {clash.Line}.",
                      "Two of one name have to be told apart by what they take. "
                      + "No argument could choose between these.");
                continue;
            }

            existing.Add((signature, fn.Name.Line));
        }

        foreach (var (name, alternatives) in overloads)
            globals.Declare(name,
                            alternatives.Count == 1
                                ? alternatives[0].Signature
                                : new EmType.Overloads([.. alternatives.Select(a => a.Signature)]));

        // Top-level statements are a block too, grouped per file — a project of many
        // files has many top levels, and comparing across them is meaningless.
        foreach (var perFile in program.GroupBy(s => fileOf?.GetValueOrDefault(s) ?? fileName))
            CheckIndentation([.. perFile], perFile.Key);

        foreach (var stmt in program)
        {
            _file = fileOf?.GetValueOrDefault(stmt) ?? fileName;
            CheckStmt(stmt, globals);
        }
    }

    /// <summary>
    /// Whether no call could tell two signatures apart — §3.2's overlap.
    ///
    /// Defaults are applied first, which is why the rule is stated over an arity
    /// <em>range</em>: <c>f(a: Int)</c> and <c>f(a: Int, b: Int = 0)</c> both answer a
    /// one-argument call, and C#'s own guidance is to avoid exactly that pairing. Here it
    /// is simply refused.
    /// </summary>
    private static bool Fits(EmType.Func candidate, int supplied, List<EmType> given)
    {
        if (supplied < candidate.LeastArgs || supplied > candidate.Params.Count) return false;

        for (int i = 0; i < given.Count && i < candidate.Params.Count; i++)
            if (!candidate.Params[i].Accepts(given[i])) return false;

        return true;
    }

    private static bool Indistinguishable(EmType.Func a, EmType.Func b)
    {
        for (int arity = Math.Max(a.LeastArgs, b.LeastArgs);
             arity <= Math.Min(a.Params.Count, b.Params.Count);
             arity++)
        {
            // At this arity both are callable. They are told apart only if some position
            // holds types no single argument could satisfy at once.
            bool separable = false;
            for (int i = 0; i < arity; i++)
                if (!a.Params[i].Overlaps(b.Params[i])) { separable = true; break; }

            if (!separable) return true;
        }

        return false;
    }

    /// <summary>
    /// Which declaration each overloaded call resolved to, by call site.
    ///
    /// The interpreter reads this instead of choosing again. Its own matcher inspects the
    /// values it is holding, which cannot reproduce the checker's answer even in
    /// principle: an empty list carries no element type at run time, so
    /// <c>each_of([])</c> is unresolvable there and decided here. Where the two rules
    /// differed, the checker's was the one the program had been type-checked against, so
    /// the checker's is the one that has to run.
    ///
    /// Keyed by reference. <c>Expr.Call</c> is a record, so two identical calls in
    /// different places are equal by value and would share an entry.
    /// </summary>
    public readonly Dictionary<Expr.Call, Stmt.FuncDecl> ChosenOverload =
        new(ReferenceEqualityComparer.Instance as IEqualityComparer<Expr.Call>
            ?? EqualityComparer<Expr.Call>.Default);

    private void Choose(Expr.Call call, EmType.Func chosen)
    {
        if (chosen.Origin is Stmt.FuncDecl decl) ChosenOverload[call] = decl;
    }

    private EmType.Func SignatureOf(Stmt.FuncDecl fn) =>
        new([.. fn.Params.Select(p => Resolve(p.Type))],
            Resolve(fn.ReturnType),
            RequiredCount(fn.Params)) { Origin = fn };

    /// <summary>
    /// How many arguments a caller must supply: everything up to the first parameter with
    /// a default. Parameters after that one are separately required to have defaults too,
    /// so this is a prefix count rather than a tally.
    /// </summary>
    private static int RequiredCount(List<Param> parameters)
    {
        int i = 0;
        while (i < parameters.Count && parameters[i].Default is null) i++;
        return i;
    }

    /// <summary>
    /// Records a class's shape before any body is checked, so methods can refer to fields
    /// declared below them and to other classes declared later in the file.
    /// </summary>
    private void DescribeClass(Stmt.ClassDecl decl)
    {
        var info = _classes[decl.Name.Lexeme];
        info.Kind = decl.Kind;
        info.Mirrors = Carries(decl.Attributes, "mirrors");

        foreach (var traitName in decl.Traits)
        {
            if (!_classes.TryGetValue(traitName.Lexeme, out var trait))
                Error(traitName.Line, $"No trait named {traitName.Lexeme}.");
            else if (trait.Kind != TypeKind.Trait)
                Error(traitName.Line, $"{traitName.Lexeme} is a class, not a trait.",
                      $"Use 'extends {traitName.Lexeme}' to inherit from a class.");
            else info.Traits.Add(trait);
        }

        if (decl.BaseName is not null)
        {
            if (_classes.TryGetValue(decl.BaseName.Lexeme, out var baseInfo))
            {
                if (baseInfo.IsSubclassOf(info))
                    Error(decl.BaseName.Line,
                          $"{decl.Name.Lexeme} and {decl.BaseName.Lexeme} extend each other.");
                else info.Base = baseInfo;
            }
            else
            {
                Error(decl.BaseName.Line, $"No class named {decl.BaseName.Lexeme}.");
            }
        }

        DescribeMembers(info, decl.Name.Lexeme, decl.Members);

        // A class with no constructor of its own inherits its base's, matching EmClass.
        if (!info.HasConstructor && info.Base is not null)
            info.ConstructorParams = info.Base.ConstructorParams;

        // A struct with no constructor gets one from its fields, in declaration order
        // (§3.2). Close to mandatory rather than a convenience: a struct is immutable, so
        // without a constructor there is no moment at which its fields could ever be given
        // values, and the type is unusable. The design document's own Vector3 sample
        // assumed this and did not compile.
        //
        // Every stored field is a parameter, including one with an initializer. The
        // alternative — an initialized field drops out of the parameter list — reads well
        // until someone adds an initializer to an existing field and silently changes the
        // arity of every call. When default parameter values land, a field's initializer
        // should become that parameter's default, which fixes this additively.
        if (!info.HasConstructor && info.Base is null && decl.Kind == TypeKind.Struct)
            info.ConstructorParams =
                [.. decl.Members.OfType<Stmt.VarDecl>()
                       .Where(f => !f.IsStatic && f.Getter is null)
                       .Select(f => Resolve(f.Type))];
    }

    /// <summary>
    /// What a body declares, recorded on the type. Shared by classes and enums, since an
    /// enum is a ClassInfo with a different Kind and its methods are ordinary ones.
    /// </summary>
    private void DescribeMembers(ClassInfo info, string typeName, List<Stmt> members)
    {
        foreach (var member in members)
        {
            switch (member)
            {
                case Stmt.VarDecl field:
                {
                    var fieldType = field.Type is not null ? Resolve(field.Type) : EmType.Any;
                    if (field.IsStatic) info.StaticFields[field.Name.Lexeme] = fieldType;
                    else info.Fields[field.Name.Lexeme] = fieldType;

                    if (field.Init is not null) info.InitializedFields.Add(field.Name.Lexeme);

                    if (field.Getter is not null)
                    {
                        info.PropertyNames.Add(field.Name.Lexeme);
                        if (field.Setter is null) info.ReadOnlyProperties.Add(field.Name.Lexeme);
                    }
                    break;
                }

                case Stmt.FuncDecl method:
                {
                    // Methods overload on the same rule functions do (§3.2): two of one
                    // name are fine when no call could confuse them, and the pair that
                    // could is refused here rather than at every call site.
                    var table = method.IsStatic ? info.StaticMethods : info.Methods;
                    var signature = SignatureOf(method);

                    if (!table.TryGetValue(method.Name.Lexeme, out var existing))
                        table[method.Name.Lexeme] = existing = [];

                    if (existing.Any(e => Indistinguishable(e, signature)))
                    {
                        Error(method.Name.Line,
                              $"{typeName}.{method.Name.Lexeme} already has an "
                              + "overload matching this one.",
                              "Two of one name have to be told apart by what they take. "
                              + "No argument could choose between these.");
                        break;
                    }

                    existing.Add(signature);
                    if (!method.IsStatic && method.Body is null)
                        info.AbstractNames.Add(method.Name.Lexeme);
                    break;
                }

                case Stmt.ConstructorDecl ctor:
                    info.HasConstructor = true;
                    info.ConstructorParams = [.. ctor.Params.Select(p => Resolve(p.Type))];
                    info.ConstructorRequired = RequiredCount(ctor.Params);
                    break;
            }
        }

    }

    /// <summary>
    /// An enum's values are constants of its own type, so §3.4's constant casing applies
    /// to them — <c>Color.RED</c>, not <c>Color.red</c>. That needs no new rule.
    /// </summary>
    private void CheckEnum(Stmt.EnumDecl decl, Scope scope)
    {
        CheckAttributes(decl.Attributes, "type");

        CheckCasing(decl.Name, "type");

        if (decl.Members.Count == 0)
            Error(decl.Name.Line,
                  $"{decl.Name.Lexeme} has no values.",
                  "An enum is a closed set of names, and an empty one names nothing:  "
                  + $"enum {decl.Name.Lexeme} {{ FIRST, SECOND }}");

        HashSet<string> seen = [];
        foreach (var member in decl.Members)
        {
            if (!seen.Add(member.Lexeme))
                Error(member.Line,
                      $"{decl.Name.Lexeme} already has a value named {member.Lexeme}.");

            if (member.Lexeme == "values")
                Error(member.Line,
                      $"{decl.Name.Lexeme} cannot have a value named values.",
                      $"{decl.Name.Lexeme}.values is how you ask an enum for all of them.");

            CheckCasing(member, "enum value", isConst: true);
        }

        CheckEnumMembers(decl, scope);
    }

    /// <summary>
    /// An enum's methods. §3.2 said "no methods" and meant "no payloads" — a tagged union
    /// is a different feature, but a fact about a value belongs on the value, and without
    /// this every one of them was a static parked on an unrelated type, which is the
    /// global-operating-on-a-receiver shape §3.2 exists to not have.
    /// </summary>
    private void CheckEnumMembers(Stmt.EnumDecl decl, Scope scope)
    {
        if (decl.Methods is not { Count: > 0 } methods) return;

        var info = _classes[decl.Name.Lexeme];
        var previousType = _currentType;
        _currentType = info;

        // `self` is the value the method was called on. An enum has no fields, so that is
        // the whole of what a body can reach beyond its own parameters.
        var body = new Scope(scope, functionBoundary: true);
        body.Declare("self", new EmType.Obj(info));

        foreach (var member in methods)
            switch (member)
            {
                case Stmt.FuncDecl method when method.Body is null:
                    Error(method.Name.Line,
                          $"{decl.Name.Lexeme}.{method.Name.Lexeme} has no body.",
                          "An enum is a closed set of values, so there is nothing below it "
                          + "to supply one. Abstract members belong in a trait or a class.");
                    break;

                case Stmt.FuncDecl method:
                    CheckAttributes(method.Attributes, "function");
                    CheckCasing(method.Name, "method");
                    CheckPredicateName(method);
                    CheckReturnIsDeclared(method);
                    if (!method.IsStatic) CheckToStringShape(method);
                    CheckCallable(method.Params, method.Body, body, method.Name.Lexeme,
                                  Resolve(method.ReturnType), method.Name.Line);
                    break;

                case Stmt.VarDecl field:
                    Error(field.Name.Line,
                          $"{decl.Name.Lexeme} cannot have a {(field.IsStatic ? "static " : "")}"
                          + "variable.",
                          "An enum is a closed set of names and carries nothing else. A "
                          + "value that varies belongs on a class.");
                    break;

                default:
                    Error(decl.Name.Line, $"{decl.Name.Lexeme} can only hold values and methods.");
                    break;
            }

        _currentType = previousType;
    }

    private void CheckClass(Stmt.ClassDecl decl, Scope scope)
    {
        // Already reported as a duplicate. Checking its body against the type that won
        // the name produces errors about the wrong class entirely.
        if (_rejectedTypes.Contains(decl)) return;

        var info = _classes[decl.Name.Lexeme];
        var previousType = _currentType;
        _currentType = info;

        CheckAttributes(decl.Attributes, "type");

        // type_name answers the same question on every value there is, which is the only
        // reason it is worth having -- a class that redefined it would make "what is
        // this?" mean whatever that class decided, on exactly the values where the
        // question is hardest to answer by reading.
        foreach (var member in decl.Members)
        {
            var declared = member switch
            {
                Stmt.FuncDecl f => f.Name,
                Stmt.VarDecl v => v.Name,
                _ => null,
            };

            if (declared?.Lexeme == Signatures.TypeNameMethod)
                Error(declared.Line,
                      $"{Signatures.TypeNameMethod} is answered by every value, so a type "
                      + "cannot give it another meaning.",
                      "Name it something this type owns:  kind, label, describe.");
        }

        // @mirrors covers the whole type, not each member: a foreign API is mirrored
        // wholesale or not at all, and marking every member would be the ceremony §3.4
        // introduced the attribute to avoid.
        bool wasMirroring = _mirroring;
        _mirroring = Carries(decl.Attributes, "mirrors");

        CheckCasing(decl.Name, "type");

        // `self` is an ordinary binding, which is why `self.name` needs no special node.
        var body = new Scope(scope, functionBoundary: true);
        body.Declare("self", new EmType.Obj(info));

        // A module's own members are in scope by their bare names. Every file could
        // already see every other file's top-level functions that way, so a file's own
        // contents were the single thing it had to qualify — the asymmetry ran the wrong
        // way round. Other files still reach it as Text.repeat, which is unchanged.
        //
        // Classes are deliberately not included: §3.2 requires self. on a field, and a
        // bare static beside a qualified field would be the split that rule removes.
        if (decl.IsModule)
        {
            foreach (var (name, type) in info.StaticFields) body.Declare(name, type);

            foreach (var (name, overloads) in info.StaticMethods)
                body.Declare(name, overloads.Count == 1
                                       ? overloads[0]
                                       : new EmType.Overloads(overloads));
        }

        // `super` is this class's inherited half and nothing of its own — a view with an
        // empty method table over the same base and traits, so a lookup on it finds exactly
        // what an override replaced and never the override itself.
        if (info.Base is not null || info.Traits.Count > 0)
        {
            var above = new ClassInfo(info.Base?.Name ?? info.Name)
                { Kind = info.Kind, Base = info.Base };
            above.Traits.AddRange(info.Traits);
            body.Declare("super", new EmType.Obj(above));
        }

        foreach (var member in decl.Members)
        {
            switch (member)
            {
                case Stmt.VarDecl { Getter: not null } property:
                    CheckAttributes(property.Attributes, "variable");
                    CheckCasing(property.Name, "property", property.IsConst);
                    if (!property.IsStatic) CheckReservedMember(property.Name, "A property");
                    CheckProperty(property, info, body);
                    break;

                case Stmt.VarDecl field:
                    CheckAttributes(field.Attributes, "variable");
                    CheckCasing(field.Name, "instance variable", field.IsConst);
                    if (!field.IsStatic) CheckReservedMember(field.Name, "An instance variable");

                    // Traits carry no state (§3.2): a CLR interface cannot hold fields, so
                    // a trait names what it needs as an abstract member instead of hiding
                    // storage in you — which is how Ruby's modules become unexplainable.
                    if (decl.Kind == TypeKind.Trait)
                        Error(field.Name.Line, $"A trait cannot have instance variables.",
                              $"Require one instead:  abstract func {field.Name.Lexeme}(): ...");

                    if (field.Init is not null)
                    {
                        var actual = TypeOf(field.Init, body);
                        var table = field.IsStatic ? info.StaticFields : info.Fields;
                        var declared = table[field.Name.Lexeme];
                        if (!declared.Accepts(actual))
                            Error(field.Name.Line,
                                  $"{field.Name.Lexeme} is declared {declared.Show()} "
                                  + $"but is given {actual.Show()}.",
                                  Widening(declared, actual));
                        if (field.Type is null) table[field.Name.Lexeme] = actual;
                    }
                    break;

                case Stmt.FuncDecl method:
                    CheckAttributes(method.Attributes, "function");
                    CheckCasing(method.Name, "method");
                    if (!method.IsStatic) CheckReservedMember(method.Name, "A method");
                    CheckPredicateName(method);
                    CheckReturnIsDeclared(method);
                    if (!method.IsStatic) CheckToStringShape(method);
                    if (!method.IsStatic) CheckOverride(method, info);
                    if (method.Body is not null)
                        CheckCallable(method.Params, method.Body, body, method.Name.Lexeme,
                                      Resolve(method.ReturnType), method.Name.Line);
                    break;

                case Stmt.ConstructorDecl ctor:
                    _inConstructor = true;
                    _sawSuperCall = false;
                    CheckCallable(ctor.Params, ctor.Body, body, "constructor",
                                  EmType.Nothing);
                    CheckSuperPlacement(ctor);
                    _inConstructor = false;
                    break;


                case Stmt.ClassDecl nested:
                    CheckClass(nested, scope);
                    break;
            }
        }

        CheckFieldsGetValues(decl, info);
        CheckRequirementsAreMet(decl, info);

        // A module's own top-level code. Its statics are visible unqualified here: they
        // were written as a file's own variables and only became static fields because
        // §3.3 turns a file into a class. That says nothing about how another file reaches
        // them, which is a separate question §3.3 leaves open.
        if (decl.Initializer is { Count: > 0 } initializer)
        {
            var moduleScope = new Scope(body);
            foreach (var (field, type) in info.StaticFields)
                moduleScope.Declare(field, type, isConst: false, line: decl.Name.Line);

            CheckBlock(initializer, moduleScope);
        }

        _mirroring = wasMirroring;
        _currentType = previousType;
    }

    /// <summary>
    /// <c>override</c>, checked both ways round. §3.2 lets a subclass's method replace what
    /// it inherits, and nothing said which of the two mistakes you had made:
    ///
    ///   • meant to replace and did not — <c>func spek()</c> beside <c>speak</c> compiled,
    ///     and the dog never barked;
    ///   • did not mean to replace and did — a <c>reset</c> written without knowing the base
    ///     had one, so the base's own <c>run</c> called the wrong version and both classes
    ///     looked right in isolation. That is the fragile base class, and it is the half
    ///     that a reader cannot find by looking at the code they wrote.
    ///
    /// Required only where something is actually replaced. Implementing an abstract member
    /// replaces nothing, so <c>class Dog with Swimmer { func stamina(): Int }</c> is
    /// untouched — which keeps the common case free and leaves the rule no exceptions.
    /// </summary>
    private void CheckOverride(Stmt.FuncDecl method, ClassInfo info)
    {
        // An abstract member states a requirement rather than answering one.
        if (method.Body is null)
        {
            if (method.IsOverride)
                Error(method.Name.Line,
                      $"{method.Name.Lexeme} is abstract, so it overrides nothing.",
                      "An abstract member asks for an implementation. Only one that has a "
                      + "body can replace another.");
            return;
        }

        var replaced = info.Replaces(method.Name.Lexeme, SignatureOf(method));

        if (replaced is not null && !method.IsOverride)
        {
            Error(method.Name.Line,
                  $"{method.Name.Lexeme} replaces {replaced.Name}.{method.Name.Lexeme}, "
                  + "so it says override.",
                  $"Write:  override func {method.Name.Lexeme}(...)\n"
                  + $"If you did not mean to replace it, {replaced.Name} already has a "
                  + $"{method.Name.Lexeme} taking the same things, and calling it will now "
                  + "reach this one instead. Rename yours, or give it different parameters "
                  + "so the two are overloads.");
            return;
        }

        if (replaced is null && method.IsOverride)
            Error(method.Name.Line,
                  $"{method.Name.Lexeme} overrides nothing.",
                  Suggest(method.Name.Lexeme,
                          info.Base?.MemberNames()
                              .Concat(info.Traits.SelectMany(t => t.MemberNames())) ?? [])
                  ?? (info.Base is null && info.Traits.Count == 0
                          ? $"{info.Name} extends nothing and mixes in nothing, so there is "
                            + "no implementation for it to replace."
                          : $"Nothing {info.Name} inherits has a {method.Name.Lexeme} with a "
                            + "body taking these parameters. An override replaces one "
                            + "version, so the parameters have to match it. Drop the "
                            + "override, or match what it takes."));
    }

    /// <summary>
    /// A class answering an abstract requirement has to answer the one that was asked.
    ///
    /// Only the name was checked before, so <c>abstract func label(): String</c> was
    /// satisfied by <c>func label(size: Int): Int</c> — wrong arity, wrong parameters,
    /// wrong return type, all accepted, for traits and abstract classes alike. §3.2 rests
    /// a good deal on traits being contracts, and an unchecked contract is a comment.
    ///
    /// An unannotated requirement asks for nothing in particular and is satisfied by
    /// anything: the operator traits are written <c>abstract func add(other)</c>, and a
    /// type's own <c>add</c> takes and returns itself. That is the point of them.
    /// </summary>
    private void CheckRequirementsAreMet(Stmt.ClassDecl decl, ClassInfo info)
    {
        foreach (string name in info.Required().Distinct())
        {
            // Still abstract here, or answered somewhere up the chain that already
            // checked it. Either way this class is not the one making the claim.
            if (info.AbstractNames.Contains(name)) continue;
            if (!info.Methods.TryGetValue(name, out var given)) continue;
            if (info.Requirement(name) is not { } required) continue;

            // The operator traits carry diagnostics written for them — `compare` returning
            // the wrong type is answered by explaining what compare means and pointing at
            // the comparison. A generic shape mismatch would pre-empt the better message.
            if (Prelude.TypeNames.Contains(required.Owner.Name)) continue;

            if (given.Any(f => Answers(f, required.Wanted))) continue;

            var first = given[0];
            Error(decl.Name.Line,
                  $"{decl.Name.Lexeme}.{name} does not match what "
                  + $"{required.Owner.Name} asks for.",
                  $"{required.Owner.Name} declares {Signature(name, required.Wanted)}, "
                  + $"and this is {Signature(name, first)}.");
        }
    }

    /// <summary>Whether one method can stand as the answer to a declared requirement.</summary>
    private static bool Answers(EmType.Func given, EmType.Func wanted) =>
        given.Params.Count == wanted.Params.Count
        && given.LeastArgs <= wanted.LeastArgs
        && given.Params.Zip(wanted.Params).All(p => p.First.Overlaps(p.Second))
        && wanted.Return.Accepts(given.Return);

    /// <summary>An unannotated parameter shows as "anything" rather than as "?", which is
    /// what <see cref="EmType.Unknown"/> prints and means nothing to a reader.</summary>
    /// <summary>
    /// <c>.or(fallback)</c> and <c>.must()</c> on a <c>T?</c>, which both give back a
    /// <c>T</c> — so the fallback has to be one, and there has to be exactly one of it.
    /// </summary>
    private EmType CheckFallback(EmType receiver, Expr.Call c, List<EmType> args, Token name)
    {
        var held = receiver.Stripped;
        int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);

        if (name.Lexeme == "must")
        {
            if (supplied > 0)
                Error(name.Line, $".must() takes no arguments, but got {supplied}.",
                      $"It says the value is there. To supply one for when it is not, "
                      + $"that is .or({Source.Of(c.Args[0])}).");
            return held;
        }

        if (supplied != 1)
        {
            Error(name.Line,
                  supplied == 0
                      ? $".or() needs the value to use when there is none."
                      : $".or() takes one argument, but got {supplied}.",
                  $"Write what {receiver.Show()} should come to when it holds nothing:  "
                  + $".or({Example(held)})");
            return held;
        }

        if (!held.Accepts(args[0]))
            Error(name.Line,
                  $"This is {receiver.Show()}, so the fallback is {held.Show()}, "
                  + $"but this is {args[0].Show()}.",
                  Widening(held, args[0])
                  ?? $".or gives back {Article(held.Show()).ToLowerInvariant()} "
                     + $"{held.Show()} whichever way it goes, so both sides have to agree.");

        return held;
    }

    /// <summary>A value of this type, for showing in a hint.</summary>
    private static string Example(EmType type) => type switch
    {
        _ when type.Equals(EmType.Int) => "0",
        _ when type.Equals(EmType.Float) => "0.0",
        _ when type.Equals(EmType.String) => "\"\"",
        _ when type.Equals(EmType.Bool) => "false",
        EmType.Lst => "[]",
        _ => "...",
    };

    /// <summary>
    /// Why one block does not fit where another was wanted. An unannotated block parameter
    /// has no type to print, so the shapes alone read as <c>func()</c> against
    /// <c>func(?)</c> — true, and no help at all about what to change.
    /// </summary>
    private static string? BlockShape(EmType wanted, EmType got) =>
        wanted is EmType.Func w && got is EmType.Func g && w.Params.Count != g.Params.Count
            ? $"This block takes {Parameters(g.Params.Count)}, and the one wanted "
              + $"takes {Parameters(w.Params.Count)}."
            : null;

    private static string Parameters(int n) => n == 0 ? "none" : Count(n, "parameter");

    private static string Signature(string name, EmType.Func fn) =>
        $"{name}({string.Join(", ", fn.Params.Select(Named))}): {Named(fn.Return)}";

    private static string Named(EmType type) =>
        type is EmType.Unknown ? "anything" : type.Show();

    // ---- definite assignment --------------------------------------------

    /// <summary>
    /// Every non-nullable field must hold something by the time a constructor finishes.
    ///
    /// Without this, <c>class Tag { var name: String }</c> builds and leaves
    /// <c>name</c> holding <c>nothing</c> while the checker goes on insisting it is a
    /// <c>String</c> — the one promise §3.2 makes, broken in silence, and the failure
    /// surfacing later at whatever line first calls a method on it. Which is precisely
    /// the null-reference experience non-nullable types exist to abolish.
    /// </summary>
    private void CheckFieldsGetValues(Stmt.ClassDecl decl, ClassInfo info)
    {
        // A trait holds no state, and an abstract class is never instantiated directly —
        // whichever concrete class extends it answers for the fields.
        if (decl.Kind == TypeKind.Trait || info.Missing().Any()) return;

        var constructor = decl.Members.OfType<Stmt.ConstructorDecl>().FirstOrDefault();

        // A struct with no constructor of its own gets the implicit one, which fills
        // every field by definition (§3.2).
        if (constructor is null && decl.Kind == TypeKind.Struct && info.Base is null) return;

        if (constructor is null)
        {
            // With no constructor here, the one that runs is the base's, and it cannot
            // know about fields this class added below it. Fields inherited from the base
            // are the base's own problem, and were reported when it was checked.
            List<string> ownFields =
                [.. info.Fields
                       .Where(f => !info.InitializedFields.Contains(f.Key)
                                   && !info.PropertyNames.Contains(f.Key)
                                   && f.Value is not EmType.Unknown
                                   && !f.Value.IsMaybe)
                       .Select(f => f.Key)];

            if (ownFields.Count == 0) return;

            Error(decl.Name.Line,
                  $"{decl.Name.Lexeme} has no constructor, so "
                  + $"{Join(ownFields)} would never be given a value.",
                  $"Add one:  constructor({ownFields[0]}: ...) {{ self.{ownFields[0]} = {ownFields[0]} }}"
                  + "\n  Or give the field a value where it is declared, or declare it "
                  + "nullable with ? if it may genuinely be missing.",
                  topic: "field-needs-value");
            return;
        }

        CheckReadsBeforeAssignment(constructor, info);

        var flow = AssignedBy(constructor.Body, []);

        // Every way out of the constructor that produces an object: each `return`, plus
        // running off the end. A `throw` is not one — it abandons the object, so nothing
        // ever observes its fields.
        List<HashSet<string>> exits = [.. flow.Exits];
        if (flow.Completes) exits.Add(flow.Assigned);

        // No exit at all means every path throws, and no instance escapes to be examined.
        HashSet<string> guaranteed = exits.Count == 0
            ? [.. info.FieldsNeedingAValue().Select(f => f.Name)]
            : [.. exits.Aggregate((a, b) => [.. a.Intersect(b)])];

        List<string> missed =
            [.. info.FieldsNeedingAValue()
                   .Where(f => !guaranteed.Contains(f.Name))
                   .Select(f => f.Name)];

        if (missed.Count == 0) return;

        Error(constructor.Keyword.Line,
              $"This constructor leaves {Join(missed)} without a value.",
              $"Assign it here:  self.{missed[0]} = ...\n"
              + "  Only assignments written directly in the constructor count — a helper "
              + "method cannot be seen to have done it.",
              topic: "field-needs-value");
    }

    /// <summary>
    /// A field read before the constructor has given it a value.
    ///
    /// Definite assignment checks the <em>end</em> of the constructor, which is necessary
    /// and not sufficient. Before its assignment a non-nullable String is observably
    /// nothing, so <c>self.name.count()</c> written above <c>self.name = name</c> compiled
    /// and then failed with "Cannot call count on nothing" -- <strong>on a field the type
    /// system had promised could not be missing</strong>. Reported from outside.
    ///
    /// Conservative in the same direction as the analysis it complements: a read is only
    /// refused where no path to it has assigned the field. A branch that assigns on both
    /// sides counts, because control cannot arrive having done neither.
    ///
    /// Two further doors, which reading alone does not cover. A constructor may not call
    /// a method on the object it is building, and may not pass that object anywhere. Both
    /// hand a half-built instance to code that will read whatever it likes -- and the
    /// second is not fixable by ordering, because a base constructor cannot know whether
    /// a subclass below it has run. Emerald has no sealed, so every class is open and
    /// every constructor is potentially a base constructor.
    ///
    /// The ban is flat rather than staged on assignment because 130 constructors across
    /// the corpus contained no use of either -- every occurrence was a test written to
    /// demonstrate the hole. A rule that costs nothing should be the simple one.
    /// </summary>
    private void CheckReadsBeforeAssignment(Stmt.ConstructorDecl constructor, ClassInfo info)
    {
        // Not gated on owing anything: a base whose own fields all have values can still
        // leak self to a subclass field that has none.
        HashSet<string> owed = [.. info.FieldsNeedingAValue().Select(f => f.Name)];

        WalkBody(constructor.Body, []);

        // Returns what is assigned once this body has run, so a caller can carry it on.
        HashSet<string> WalkBody(List<Stmt> body, HashSet<string> incoming)
        {
            HashSet<string> assigned = [.. incoming];

            foreach (var stmt in body)
                switch (stmt)
                {
                    // A plain `=` gives the field a value. Anything else -- `+=` and the
                    // rest -- reads it first, which AssignedBy already refuses to count
                    // and which this has to see as a read.
                    case Stmt.Assign a
                        when a.Target is Expr.Get { Target: Expr.Variable { Name.Lexeme: "self" } } g:
                        Reads(a.Value, assigned);
                        if (a.Op.Type is TokenType.Assign) assigned.Add(g.Name.Lexeme);
                        else Report(g.Name, assigned);
                        break;

                    case Stmt.Assign a:
                        Reads(a.Target, assigned);
                        Reads(a.Value, assigned);
                        break;

                    case Stmt.If i:
                    {
                        Reads(i.Condition, assigned);
                        var then = WalkBody(i.Then, assigned);

                        // Without an else, reaching the next statement may mean the branch
                        // did not run, so it guarantees nothing.
                        assigned = i.Else is null
                            ? assigned
                            : [.. then.Intersect(WalkBody(i.Else, assigned))];
                        break;
                    }

                    // A loop may run zero times, so nothing inside it is guaranteed to
                    // have happened by the statement below.
                    case Stmt.While w:
                        Reads(w.Condition, assigned);
                        WalkBody(w.Body, assigned);
                        break;

                    case Stmt.For f:
                        Reads(f.Iterable, assigned);
                        WalkBody(f.Body, assigned);
                        break;

                    case Stmt.TryCatch t:
                        WalkBody(t.Body, assigned);
                        foreach (var clause in t.Clauses) WalkBody(clause.Body, assigned);
                        break;

                    case Stmt.VarDecl { Init: not null } v: Reads(v.Init, assigned); break;
                    case Stmt.ExprStmt e: Reads(e.Expression, assigned); break;
                    case Stmt.Return { Value: not null } r: Reads(r.Value, assigned); break;
                    case Stmt.Throw th: Reads(th.Value, assigned); break;
                    case Stmt.Assert asrt: Reads(asrt.Condition, assigned); break;
                }

            return assigned;
        }

        void Report(Token name, HashSet<string> assigned)
        {
            if (!owed.Contains(name.Lexeme) || assigned.Contains(name.Lexeme)) return;

            Error(name.Line,
                  $"{name.Lexeme} is read here, before the constructor gives it a value.",
                  $"Until it is assigned it holds nothing, whatever its type says. Move "
                  + $"self.{name.Lexeme} = ... above this line.",
                  topic: "field-needs-value");
        }

        // A method, as opposed to a field that happens to hold a function. Calling a
        // function out of a field dispatches to nothing and is safe once the field is
        // assigned, which the read check already covers.
        void ReportCall(Token name)
        {
            if (info.FindMethods(name.Lexeme).Count == 0) return;

            Error(name.Line,
                  $"A constructor cannot call {name.Lexeme} on the object it is building.",
                  $"The object is not finished yet, and {name.Lexeme} may be overridden by a "
                  + "subclass whose own fields are still unset.\n"
                  + $"  Call it after the object exists:  var it = {info.Name}(...)\n"
                  + $"                                    it.{name.Lexeme}()",
                  topic: "self-during-construction");
        }

        void ReportEscape(Token where)
        {
            Error(where.Line,
                  "self cannot be passed out of a constructor.",
                  "The object is not finished being built, so whatever receives it can read "
                  + "fields that hold nothing.\n"
                  + "  Hand it over once construction is done, from the code that built it.",
                  topic: "self-during-construction");
        }

        void Reads(Expr expr, HashSet<string> assigned)
        {
            switch (expr)
            {
                case Expr.Get { Target: Expr.Variable { Name.Lexeme: "self" } } g:
                    Report(g.Name, assigned);
                    break;

                // self reached as a value rather than as the left of a dot: an argument,
                // an element, the right of an assignment. The case above catches every
                // legitimate self.x, so arriving here means it is escaping.
                case Expr.Variable { Name.Lexeme: "self" } v:
                    ReportEscape(v.Name);
                    break;

                case Expr.Call { Callee: Expr.Get { Target: Expr.Variable { Name.Lexeme: "self" } } gc } c2:
                    ReportCall(gc.Name);
                    Report(gc.Name, assigned);
                    foreach (var arg in c2.Args) Reads(arg, assigned);
                    if (c2.Trailing is not null) Reads(c2.Trailing, assigned);
                    break;

                case Expr.Call c:
                    Reads(c.Callee, assigned);
                    foreach (var arg in c.Args) Reads(arg, assigned);
                    if (c.Trailing is not null) Reads(c.Trailing, assigned);
                    break;

                case Expr.Binary b: Reads(b.Left, assigned); Reads(b.Right, assigned); break;
                case Expr.Logical l: Reads(l.Left, assigned); Reads(l.Right, assigned); break;
                case Expr.Unary u: Reads(u.Right, assigned); break;
                case Expr.Grouping g: Reads(g.Inner, assigned); break;
                case Expr.Get g: Reads(g.Target, assigned); break;
                case Expr.Index x: Reads(x.Target, assigned); Reads(x.Position, assigned); break;
                case Expr.RangeExpr r: Reads(r.Start, assigned); Reads(r.End, assigned); break;
                case Expr.ListLiteral l: foreach (var i in l.Items) Reads(i, assigned); break;
                case Expr.Interpolation p: foreach (var i in p.Parts) Reads(i, assigned); break;
                case Expr.TypeTest t: Reads(t.Value, assigned); break;
                case Expr.TypeCast c2: Reads(c2.Value, assigned); break;
                case Expr.IfExpr i:
                    Reads(i.Condition, assigned);
                    Reads(i.Then, assigned);
                    Reads(i.Else, assigned);
                    break;
                case Expr.DictLiteral d:
                    foreach (var e in d.Entries) { Reads(e.Key, assigned); Reads(e.Value, assigned); }
                    break;
            }
        }
    }

    private static string Join(List<string> names) =>
        names.Count == 1 ? names[0]
            : string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1];

    /// <summary>
    /// The result of walking a statement list: what is assigned if control reaches the
    /// end, whether it can reach the end at all, and what was assigned at each
    /// <c>return</c> along the way.
    ///
    /// <c>Exits</c> is the half that is easy to leave out, and doing so is wrong in the
    /// dangerous direction. <c>return unless ok?</c> ahead of the assignments looks
    /// harmless to an analysis that only inspects the end of the body — the path that
    /// reaches the end did assign everything. The path that returned early did not, and it
    /// still handed back a constructed object.
    /// </summary>
    private sealed record Flow(HashSet<string> Assigned, bool Completes, List<HashSet<string>> Exits);

    /// <summary>
    /// Which <c>self.</c> fields are assigned along each way out of this body.
    /// Deliberately conservative: a loop may run zero times and a <c>try</c> may fail
    /// partway, so neither promises anything on its own. Being wrong in this direction
    /// costs a diagnostic the programmer can satisfy; being wrong in the other direction
    /// is the hole this exists to close.
    /// </summary>
    private static Flow AssignedBy(List<Stmt> body, HashSet<string> incoming)
    {
        HashSet<string> assigned = [.. incoming];
        List<HashSet<string>> exits = [];

        foreach (var stmt in body)
        {
            switch (stmt)
            {
                // Only a plain `=` counts. `self.n += 1` reads the field first, so it is
                // a use of an unset value rather than a way to give it one.
                case Stmt.Assign { Op.Type: TokenType.Assign } a
                    when a.Target is Expr.Get { Target: Expr.Variable { Name.Lexeme: "self" } } g:
                    assigned.Add(g.Name.Lexeme);
                    break;

                case Stmt.Return:
                    exits.Add([.. assigned]);
                    return new Flow(assigned, false, exits);

                // A throw abandons the object rather than returning it, so its fields are
                // never observed and it is not an exit that owes them anything.
                case Stmt.Throw:
                    return new Flow(assigned, false, exits);

                case Stmt.If i:
                {
                    var then = AssignedBy(i.Then, assigned);
                    exits.AddRange(then.Exits);

                    // No else: reaching the next statement may mean the condition was
                    // false, so the branch guarantees nothing.
                    if (i.Else is null) break;

                    var otherwise = AssignedBy(i.Else, assigned);
                    exits.AddRange(otherwise.Exits);

                    if (!then.Completes && !otherwise.Completes)
                        return new Flow(assigned, false, exits);

                    // A branch that cannot complete cannot be the one we arrived by, so
                    // the other branch's guarantees stand alone.
                    assigned =
                        !then.Completes ? otherwise.Assigned
                        : !otherwise.Completes ? then.Assigned
                        : [.. then.Assigned.Intersect(otherwise.Assigned)];
                    break;
                }

                case Stmt.TryCatch t:
                {
                    List<Flow> arms = [AssignedBy(t.Body, assigned)];
                    arms.AddRange(t.Clauses.Select(c => AssignedBy(c.Body, assigned)));
                    foreach (var arm in arms) exits.AddRange(arm.Exits);

                    var reaching = arms.Where(a => a.Completes).ToList();
                    if (reaching.Count == 0) return new Flow(assigned, false, exits);

                    // The try body can fail at any point, so only what every arm that can
                    // reach the next statement also guarantees survives.
                    assigned = reaching.Skip(1).Aggregate(
                        reaching[0].Assigned,
                        (kept, arm) => [.. kept.Intersect(arm.Assigned)]);
                    break;
                }

                // A loop body may run zero times, so nothing it assigns is guaranteed —
                // but a return inside it is still a way out, and still owes the fields.
                case Stmt.While w:
                    exits.AddRange(AssignedBy(w.Body, assigned).Exits);
                    break;

                case Stmt.For f:
                    exits.AddRange(AssignedBy(f.Body, assigned).Exits);
                    break;

                // Neither leaves the constructor; both only end a turn of a loop, and a
                // loop contributes nothing either way.
                case Stmt.Break or Stmt.Continue:
                    return new Flow(assigned, false, exits);
            }
        }

        return new Flow(assigned, true, exits);
    }

    /// <summary>
    /// A property is a var with a body. The getter sees <c>self</c>; the setter also sees
    /// <c>value</c>, which is the incoming assignment.
    /// </summary>
    private void CheckProperty(Stmt.VarDecl property, ClassInfo info, Scope body)
    {
        CheckCallable([], property.Getter!, body, property.Name.Lexeme,
                      info.Fields.GetValueOrDefault(property.Name.Lexeme, EmType.Any),
                      property.Name.Line);

        if (property.Setter is null) return;

        var setterScope = new Scope(body, functionBoundary: true);
        setterScope.Declare("value",
                            info.Fields.GetValueOrDefault(property.Name.Lexeme, EmType.Any));
        _returnTypes.Push((property.Name.Lexeme, EmType.Nothing));
        CheckBlock(property.Setter, setterScope);
        _returnTypes.Pop();
    }

    private void CheckCallable(List<Param> parameters, List<Stmt> body, Scope outer,
                               string what, EmType returns, int line = 0)
    {
        var inner = new Scope(outer, functionBoundary: true);
        foreach (var p in parameters)
        {
            if (p.Type is null)
                Error(p.Name.Line,
                      $"Parameter {p.Name.Lexeme} needs a type.",
                      "Types are inferred inside a body but written at its edges: "
                      + $"{what}({p.Name.Lexeme}: Int) ...");

            CheckCasing(p.Name, "parameter");
            CheckDefault(p, inner);
            inner.Declare(p.Name.Lexeme, Resolve(p.Type), line: p.Name.Line);
        }

        CheckDefaultsComeLast(parameters);

        _returnTypes.Push((what, returns));
        CheckBlock(body, inner);
        _returnTypes.Pop();

        MustReturn(returns, body, what, line);
    }

    /// <summary>
    /// A default's value must fit the parameter it belongs to. Checked in the scope built
    /// so far — before the parameter itself is declared — so a default may refer to a
    /// parameter to its left but not to itself.
    /// </summary>
    private void CheckDefault(Param p, Scope soFar)
    {
        if (p.Default is null) return;

        var declared = Resolve(p.Type);
        var actual = TypeOf(p.Default, soFar);

        if (!declared.Accepts(actual))
            Error(p.Name.Line,
                  $"{p.Name.Lexeme} is declared {declared.Show()} "
                  + $"but its default is {actual.Show()}.",
                  Widening(declared, actual));
    }

    /// <summary>
    /// Once a parameter has a default, every parameter after it must have one too.
    /// Otherwise there is no way to supply the later argument without the earlier — the
    /// caller has only positions to work with, and skipping one is not a position.
    /// </summary>
    private void CheckDefaultsComeLast(List<Param> parameters)
    {
        int firstDefault = parameters.FindIndex(p => p.Default is not null);
        if (firstDefault < 0) return;

        foreach (var p in parameters.Skip(firstDefault).Where(p => p.Default is null))
            Error(p.Name.Line,
                  $"{p.Name.Lexeme} has no default, but {parameters[firstDefault].Name.Lexeme} "
                  + "before it does.",
                  "Arguments are matched by position, so a parameter after a defaulted one "
                  + $"could never be given a value. Move {p.Name.Lexeme} earlier, or give it "
                  + "a default too.");
    }

    // ---- statements -----------------------------------------------------

    private void CheckStmt(Stmt stmt, Scope scope)
    {
        switch (stmt)
        {
            case Stmt.VarDecl v: CheckVarDecl(v, scope); break;
            case Stmt.Assign a: CheckAssign(a, scope); break;
            case Stmt.ExprStmt e: CheckExpressionStatement(e, scope); break;
            case Stmt.If i: CheckIf(i, scope); break;

            case Stmt.While w:
                Expect(TypeOf(w.Condition, scope), EmType.Bool, w.Condition, "a while condition");
                _loopDepth++;
                CheckBlock(w.Body, new Scope(scope));
                _loopDepth--;
                break;

            case Stmt.Break b: CheckLoopJump(b.Keyword, "break"); break;
            case Stmt.Continue c2: CheckLoopJump(c2.Keyword, "continue"); break;

            case Stmt.For f: CheckFor(f, scope); break;
            case Stmt.PairDecl pd: CheckPairDecl(pd, scope); break;
            case Stmt.FuncDecl fn: CheckFunc(fn, scope); break;
            case Stmt.ClassDecl c: CheckClass(c, scope); break;
            case Stmt.EnumDecl e: CheckEnum(e, scope); break;

            case Stmt.Throw t:
            {
                // Checked, rather than left to fail at run time. `throw 42` reached the
                // interpreter and died there, which is exactly the class of mistake a
                // checked language exists to catch before the program runs.
                var thrown = TypeOf(t.Value, scope);

                if (thrown is not EmType.Unknown
                    && !thrown.Equals(EmType.String)
                    && !IsErrorType(thrown))
                    Error(t.Keyword.Line,
                          $"Cannot throw {thrown.Show()}.",
                          $"Throw a String, or a type that extends {Prelude.ErrorType}:  "
                          + $"throw {Prelude.ErrorType}(\"...\")");
                break;
            }

            case Stmt.Assert a:
                Expect(TypeOf(a.Condition, scope), EmType.Bool, a.Condition, "assert",
                       a.Keyword.Line);
                break;

            case Stmt.TryCatch tc:
            {
                CheckBlock(tc.Body, new Scope(scope));
                CheckCatchClauses(tc, scope);
                break;
            }

            case Stmt.Return r:
            {
                if (_returnTypes.Count == 0)
                {
                    if (r.Value is not null) TypeOf(r.Value, scope);
                    Error(r.Keyword.Line, "return can only appear inside a function.");
                    break;
                }

                var (what, wanted) = _returnTypes.Peek();

                if (r.Value is null)
                {
                    if (wanted is not EmType.Unknown && !wanted.Equals(EmType.Nothing))
                        Error(r.Keyword.Line,
                              $"{what} returns {wanted.Show()}, but this return has no value.");
                    break;
                }

                var given = TypeOf(r.Value, scope, wanted);

                if (wanted.Equals(EmType.Nothing))
                {
                    Error(r.Keyword.Line, $"{what} returns nothing, but this returns a value.",
                          what == "constructor"
                              ? "A constructor gives back the object it is building. A plain "
                                + "`return` leaves it early."
                              : "Leave the value off.");
                    break;
                }

                if (given is not EmType.Unknown && !wanted.Accepts(given))
                    Error(LineOf(r.Value) is var line && line > 0 ? line : r.Keyword.Line,
                          $"{what} returns {wanted.Show()}, but this is {given.Show()}.",
                          Widening(wanted, given));
                break;
            }
        }
    }

    /// <summary>
    /// A statement that computes a value and drops it is a mistake (§3.1). This is the
    /// whole safety net for a forgotten <c>()</c>: since a bare name is no longer a call,
    /// <c>exit</c> and <c>rex.speak</c> alone are caught here rather than running.
    /// </summary>
    private void CheckExpressionStatement(Stmt.ExprStmt statement, Scope scope)
    {
        var type = TypeOf(statement.Expression, scope);

        // At a prompt a bare expression is the request, not a mistake: typing `1 + 1` to
        // see 2 is the whole point of having one. §3.1's rule is about a statement in a
        // program computing something and dropping it, which is a different act.
        if (interactive) return;

        // A checker that already reported something here has nothing to add.
        if (type is EmType.Unknown) return;

        // The mistake this change creates, so it is the one worth naming precisely: what
        // was written is the function, and the parentheses that would run it are missing.
        if (type is EmType.Func fn && Uncalled(statement.Expression) is { } written)
        {
            Error(LineOf(statement.Expression),
                  $"This names {written} without calling it.",
                  $"It is {fn.Show()}. Add parentheses to run it:  {written}()");
            return;
        }

        if (statement.Expression is Expr.Variable name)
        {
            Error(name.Name.Line,
                  $"This does nothing — {name.Name.Lexeme} is looked up and thrown away.",
                  $"Did you mean to call it, or to use the value?  var result = {name.Name.Lexeme}");
            return;
        }

        if (statement.Expression is Expr.Get read)
            Error(read.Name.Line,
                  $"This does nothing — {read.Name.Lexeme} is read and thrown away.",
                  $"Did you mean to use the value?  var result = {Source.Of(statement.Expression)}");

        if (statement.Expression is Expr.Binary or Expr.Unary)
            Error(LineOf(statement.Expression), "This does nothing.",
                  "Its result is computed and then thrown away.");
    }

    /// <summary>
    /// How an uncalled function was written, if it was written as a plain name or member
    /// read. A lambda dropped on its own line is a different mistake and gets the general
    /// message, since there is no <c>()</c> to suggest adding to it.
    /// </summary>
    private static string? Uncalled(Expr expression) => expression switch
    {
        Expr.Variable v => v.Name.Lexeme,
        Expr.Get g => Source.Of(g),
        _ => null,
    };

    /// <summary>
    /// <c>super(...)</c> goes first, and goes in at all when the base needs arguments.
    ///
    /// First because the alternative is reading an inherited field before the base has
    /// filled it — the null-reference shape §3.2 exists to remove, arriving through the
    /// one door definite assignment cannot watch. Stating it as a position rather than as
    /// "before anything that reads self" costs the case where an argument wants working
    /// out first, and that case can be written inside the parentheses.
    /// </summary>
    private void CheckSuperPlacement(Stmt.ConstructorDecl ctor)
    {
        bool first = Interpreter.OpensWithSuper(ctor.Body);

        if (_sawSuperCall && !first)
        {
            Error(SuperLine(ctor.Body) ?? ctor.Keyword.Line,
                  "super(...) has to be the first statement in a constructor.",
                  "Until the base part is built, an inherited field holds nothing — so "
                  + "nothing can run before it.\nIf an argument needs working out first, "
                  + "the work can go inside the parentheses:  super(name.trim())");
            return;
        }

        if (_sawSuperCall || _currentType?.Base is not { } above) return;

        // No call written. The base's constructor still runs — implicitly, with nothing
        // passed — so this is only a problem when it needed something.
        if (above.ConstructorRequired > 0 && above.ConstructorParams.Count > 0)
            Error(ctor.Keyword.Line,
                  $"{above.Name}'s constructor needs "
                  + $"{Count(above.ConstructorRequired, "argument")}, so "
                  + $"{_currentType!.Name} has to say what to pass it.",
                  "Call it first:  super(...)\n"
                  + $"{above.Name}'s constructor takes ("
                  + string.Join(", ", above.ConstructorParams.Select(t => t.Show()))
                  + ").");
    }

    /// <summary>Where a misplaced <c>super(...)</c> was written, for the diagnostic.</summary>
    private static int? SuperLine(List<Stmt> body)
    {
        foreach (var statement in body)
            if (statement is Stmt.ExprStmt
                { Expression: Expr.Call { Callee: Expr.Variable { Name.Lexeme: "super" } v } })
                return v.Name.Line;
        return null;
    }

    private void CheckVarDecl(Stmt.VarDecl v, Scope scope)
    {
        // The annotation is resolved first so it can be handed to the initializer: a
        // block takes its parameter types from it, and an overloaded method value takes
        // which version it names from it (§3.1). Both need the shape before the value.
        EmType? annotation = v.Type is null ? null : Resolve(v.Type);

        EmType inferred = v.Init is null ? EmType.Any : TypeOf(v.Init, scope, annotation);
        EmType declared = annotation ?? inferred;

        if (v.Type is not null && v.Init is not null && !declared.Accepts(inferred))
            Error(v.Name.Line,
                  // "is given ?" says nothing. An unknown here means whatever produced the
                  // value never said what it gives back, and that is the thing to fix.
                  inferred.Stripped is EmType.Unknown
                      ? $"{v.Name.Lexeme} is declared {declared.Show()}, but what it is "
                        + "given does not say what type it is."
                      : $"{v.Name.Lexeme} is declared {declared.Show()} but is given {inferred.Show()}.",
                  // A literal is nobody's alias, so the reason a container is invariant
                  // does not apply to it and saying it would send the reader looking for
                  // a second name that is not there. What is true of a literal is simply
                  // that its items are the wrong type, and they are right here to fix.
                  inferred.Stripped is EmType.Unknown
                      ? "An unannotated function or an abstract contract asks for nothing "
                        + "in particular, so there is nothing here to check against.\n"
                        + "Give it a return type, or leave this declaration's type off and "
                        + "let it be inferred."
                      : v.Init is Expr.ListLiteral or Expr.DictLiteral
                          ? Literally(declared.Stripped, inferred.Stripped)
                          : Widening(declared, inferred));

        CheckAttributes(v.Attributes, "variable");
        CheckShadowing(v.Name, scope);
        CheckCasing(v.Name, "variable", v.IsConst);
        scope.Declare(v.Name.Lexeme, declared, v.IsConst, v.Name.Line);
    }

    private void CheckAssign(Stmt.Assign a, Scope scope)
    {
        if (a.Target is Expr.Get member)
        {
            var owner = TypeOf(member.Target, scope);
            TypeOf(a.Value, scope);

            // `a?.b = 1` reads as a write that may not happen, which is a statement whose
            // effect depends on something it does not say out loud. Swift allows it; C#
            // does not, and neither does this — the check belongs where a reader can see
            // it (§2.6).
            if (member.Optional)
                Error(a.Op.Line,
                      "?. reads a value, so it cannot be assigned through.",
                      $"Say when the write happens:  if {Source.Of(member.Target)} != nothing "
                      + $"{{ {Source.Of(member.Target)}.{member.Name.Lexeme} = ... }}");

            // Structs are immutable (§3.2). Only a struct's own constructor may write its
            // fields — which is what makes C#'s `transform.position.x = 5` unwritable here
            // rather than merely discouraged.
            if (owner is EmType.Obj { Info.Kind: TypeKind.Struct } s
                && !(_inConstructor && ReferenceEquals(_currentType, s.Info)))
            {
                Error(a.Op.Line,
                      $"{s.Info.Name} is a struct, so {member.Name.Lexeme} cannot be changed.",
                      "Structs are immutable. Build a new one instead of modifying this.",
                      topic: "struct-immutable");
            }
            return;
        }

        // a[i] = value. This was accepted by the checker and then refused by the
        // interpreter — the target was typed and the result thrown away, so nothing ever
        // asked whether it could be written to.
        if (a.Target is Expr.Index index)
        {
            CheckIndexAssign(a, index, scope);
            return;
        }

        if (a.Target is not Expr.Variable target)
        {
            TypeOf(a.Target, scope);
            return;
        }

        var binding = scope.Find(target.Name.Lexeme);
        if (binding is null)
        {
            Error(target.Name.Line, $"No variable named {target.Name.Lexeme}.",
                  MistakenForAFunction(target.Name));
            return;
        }

        if (binding.IsConst)
            Error(target.Name.Line,
                  $"{target.Name.Lexeme} is a const and cannot be reassigned.",
                  $"Declare it with var instead of const if it needs to change.");

        var value = TypeOf(a.Value, scope);
        if (!binding.Type.Accepts(value))
            Error(a.Op.Line,
                  $"{target.Name.Lexeme} holds {binding.Type.Show()}, but this gives it {value.Show()}.",
                  Widening(binding.Type, value));
    }

    /// <summary>
    /// <c>a[i] = value</c>. A list writes its element type; a user type writes through
    /// <c>set_at</c>, which is the setter half of Indexable — present means writable,
    /// absent means read-only, exactly as a property's <c>set</c> body works.
    /// </summary>
    /// <summary>
    /// <c>break</c> and <c>continue</c> need a loop, and one in the same function. The
    /// second case gets its own message because the loop is usually visible on screen,
    /// two lines up, and "there is no loop here" would read as the compiler being wrong.
    /// </summary>
    private void CheckLoopJump(Token keyword, string word)
    {
        if (_loopDepth > 0) return;

        if (_hiddenLoops > 0)
            Error(keyword.Line,
                  $"{word} cannot leave a block.",
                  $"The loop around this one is outside the block, and a block is a "
                  + $"function — {word} only affects a loop written in the same function. "
                  + "A plain for loop over the same items can use it.",
                  topic: "break-in-block");
        else
            Error(keyword.Line, $"{word} can only appear inside a loop.");
    }

    private void CheckIndexAssign(Stmt.Assign a, Expr.Index index, Scope scope)
    {
        var target = TypeOf(index.Target, scope);

        // A dictionary is keyed by whatever it was declared with, so it is settled before
        // the Int requirement that lists impose.
        if (target is EmType.Dict dict)
        {
            var key = TypeOf(index.Position, scope);
            var given = TypeOf(a.Value, scope);

            if (!dict.Key.Accepts(key))
                Error(a.Op.Line,
                      $"This dictionary is keyed by {dict.Key.Show()}, but this is {key.Show()}.",
                      Widening(dict.Key, key));

            // A compound assignment combines the old value with the new, and the old one
            // is a maybe — so what lands is the operator's result, checked where it is.
            if (a.Op.Type == TokenType.Assign && !dict.Value.Accepts(given))
                Error(a.Op.Line,
                      $"This dictionary holds {dict.Value.Show()}, "
                      + $"but this gives it {given.Show()}.",
                      Widening(dict.Value, given));

            return;
        }

        Expect(TypeOf(index.Position, scope), EmType.Int, index.Position, "an index");
        var value = TypeOf(a.Value, scope);

        // A compound assignment combines the old element with the new value, so what
        // finally lands is the operator's result rather than the right-hand side. Typing
        // that properly needs the operator machinery; until then it is left alone rather
        // than checked wrongly.
        bool compound = a.Op.Type != TokenType.Assign;

        switch (target)
        {
            case EmType.Unknown:
                return;

            case EmType.Lst list:
                if (!compound && !list.Element.Accepts(value))
                    Error(a.Op.Line,
                          $"This list holds {list.Element.Show()}, "
                          + $"but this gives it {value.Show()}.",
                          Widening(list.Element, value));
                return;

            case EmType.Obj obj:
                if (obj.Info.FindMethod(Prelude.SetAtMethod) is null)
                    Error(a.Op.Line,
                          obj.Info.FindMethod(Prelude.AtMethod) is null
                              ? $"{target.Show()} cannot be indexed with []."
                              : $"{target.Show()} can be read by position, but not written to.",
                          $"Define {Prelude.SetAtMethod}(index, value) to allow "
                          + $"{target.Show()}[i] = value.");
                return;

            default:
                Error(index.Bracket.Line, $"Cannot index {target.Show()}.",
                      target.Equals(EmType.String)
                          ? "Emerald strings are not integer-indexed. Use .chars() to get characters."
                          : null);
                return;
        }
    }

    private void CheckIf(Stmt.If i, Scope scope)
    {
        Expect(TypeOf(i.Condition, scope), EmType.Bool, i.Condition, "an if condition");

        // Flow-sensitive narrowing (§3.2): inside the then-branch, anything the condition
        // proved non-null is treated as non-null. This is the pass Kotlin calls a smart
        // cast, and it is what makes non-nullable types usable rather than tiresome.
        var thenScope = new Scope(scope);
        foreach (var (name, type) in Refinements(i.Condition, whenTrue: true, scope))
            thenScope.Declare(name, type);
        CheckBlock(i.Then, thenScope);

        if (i.Else is null) return;

        var elseScope = new Scope(scope);
        foreach (var (name, type) in Refinements(i.Condition, whenTrue: false, scope))
            elseScope.Declare(name, type);
        CheckBlock(i.Else, elseScope);
    }

    /// <summary>
    /// <c>var (name, score) = best</c>. Both names come from the pair, so neither is
    /// annotated -- writing the types would be writing them twice, and the pair already
    /// knows.
    /// </summary>
    private void CheckPairDecl(Stmt.PairDecl pd, Scope scope)
    {
        var value = TypeOf(pd.Init, scope);

        if (value is not EmType.PairOf pair)
        {
            if (value is not EmType.Unknown)
                Error(pd.First.Line,
                      $"Two names need a pair to take apart, and this is {value.Show()}.",
                      value.IsMaybe
                          ? "Deal with the maybe first:  .or(...) or a check."
                          : "Pair(a, b) makes one, and so do a dictionary's find and "
                            + "to_list.");

            pair = new EmType.PairOf(EmType.Any, EmType.Any);
        }

        foreach (var (name, held) in new[] { (pd.First, pair.First), (pd.Second, pair.Second) })
        {
            CheckShadowing(name, scope);
            CheckCasing(name, pd.IsConst ? "constant" : "variable");
            scope.Declare(name.Lexeme, held, isConst: pd.IsConst, line: name.Line);
        }
    }

    private void CheckFor(Stmt.For f, Scope scope)
    {
        var iterable = TypeOf(f.Iterable, scope);

        // What the loop variable holds is decided by what is being walked over. There is
        // no Iterable trait yet — a user type cannot be looped over, and the diagnostic
        // says so plainly rather than pretending the shape exists.
        EmType element;
        switch (iterable)
        {
            case EmType.Unknown:
                element = EmType.Any;
                break;

            case EmType.Lst list:
                element = list.Element;
                break;

            case EmType.Prim { Name: "Range" }:
                element = EmType.Int;
                break;

            // A set holds one kind of thing, so unlike a dictionary there is no question
            // about which half of it the loop variable gets.
            case EmType.SetOf set:
                element = set.Element;
                break;

            // A string yields its characters, each itself a String — §3.2 rules out
            // integer indexing, so walking it is how you reach them.
            case EmType.Prim { Name: "String" }:
                element = EmType.String;
                break;

            // A dictionary walks in pairs, and now there is a type for one -- so it is
            // loopable in the two-name form, and only in that form. `for k in ages`
            // cannot say whether k is a key or a pair, and guessing is worse than
            // refusing; `for (k, v) in ages` says so out loud.
            case EmType.Dict pairs when f.Second is not null:
                element = new EmType.PairOf(pairs.Key, pairs.Value);
                break;

            default:
                Error(f.Variable.Line,
                      $"Cannot loop over {iterable.Show()}.",
                      iterable switch
                      {
                          EmType.Dict => "A dictionary walks in pairs:  "
                                         + "for (key, value) in scores { ... }",
                          EmType.Obj => "A range, a list, a set, a string and a dictionary "
                                        + "can be looped over. For anything else, expose a "
                                        + "list from it.",
                          _ => "Loop over a range (1..5), a list, a set, or a string.",
                      },
                      topic: "loop-over");
                element = EmType.Any;
                break;
        }

        var body = new Scope(scope);
        CheckShadowing(f.Variable, scope);

        if (f.Second is { } second)
        {
            if (element is EmType.PairOf held)
            {
                body.Declare(f.Variable.Lexeme, held.First, line: f.Variable.Line);
                CheckShadowing(second, scope);
                body.Declare(second.Lexeme, held.Second, line: second.Line);
            }
            else
            {
                if (!element.Equals(EmType.Any))
                    Error(f.Variable.Line,
                          $"Two names need a pair to fill them, and this walks "
                          + $"{element.Show()}.",
                          $"Take one name:  for {f.Variable.Lexeme} in ...");

                body.Declare(f.Variable.Lexeme, EmType.Any, line: f.Variable.Line);
                body.Declare(second.Lexeme, EmType.Any, line: second.Line);
            }
        }
        else body.Declare(f.Variable.Lexeme, element, line: f.Variable.Line);

        _loopDepth++;
        CheckBlock(f.Body, body);
        _loopDepth--;
    }

    /// <summary>
    /// Checks a <c>##</c> block against the signature it sits above.
    ///
    /// §3.1 rejected Javadoc's <c>@param</c> for duplicating the signature and going
    /// stale, and that argument is right about <em>types</em> and wrong about
    /// <em>meaning</em>: what a radius is for, and that it must be positive, is not in
    /// the signature and never will be. Javadoc rots because nothing checks it; C# checks
    /// it and warns, and so does this.
    ///
    /// A warning rather than an error, because the program is correct and only the comment
    /// is wrong. And unlike C#, an undocumented parameter is not reported at all: warning
    /// on every partly documented function is how a warning becomes noise a reader learns
    /// to skip past, which is the opposite of what §2.6 asks a diagnostic to be.
    /// </summary>
    private void CheckDoc(Stmt.FuncDecl fn)
    {
        if (fn.Doc is null) return;

        var named = fn.Params.Select(p => p.Name.Lexeme).ToList();
        int line = fn.Name.Line;

        foreach (var raw in fn.Doc.Split('\n'))
        {
            var text = raw.TrimStart();

            if (text.StartsWith("@param", StringComparison.Ordinal))
            {
                // `@param radius  distance from the center` — the name is the first word
                // after the tag, and everything after it is prose nobody should parse.
                var rest = text["@param".Length..].TrimStart();
                var wanted = new string([.. rest.TakeWhile(c => !char.IsWhiteSpace(c))]);

                if (wanted.Length == 0)
                    Warn(line, "This @param does not say which parameter it describes.",
                         named.Count > 0
                             ? $"Name one of them:  @param {named[0]}  what it is for"
                             : $"{fn.Name.Lexeme} takes no parameters.");

                else if (!named.Contains(wanted))
                    Warn(line,
                         $"{fn.Name.Lexeme} has no parameter named {wanted}.",
                         named.Count == 0
                             ? $"{fn.Name.Lexeme} takes no parameters, so there is nothing "
                               + "for this line to describe."
                             : Suggest(wanted, named)
                               ?? $"It takes {string.Join(", ", named)}.");
            }

            else if (text.StartsWith("@returns", StringComparison.Ordinal)
                     && fn.ReturnType is null)
                Warn(line, $"{fn.Name.Lexeme} does not give anything back.",
                     "A function with no return type has no answer to describe. Add one "
                     + $"if it should:  func {fn.Name.Lexeme}(...): Int");
        }
    }

    private void CheckFunc(Stmt.FuncDecl fn, Scope scope)
    {
        // Declaring it makes a nested function visible to its own body, which is what
        // recursion needs. But a top-level name already carries its overload set by now,
        // and redeclaring would replace the set with whichever version is being checked —
        // so every call would resolve against the last one declared.
        if (scope.Find(fn.Name.Lexeme)?.Type is not EmType.Overloads)
            scope.Declare(fn.Name.Lexeme, SignatureOf(fn));
        CheckAttributes(fn.Attributes, "function");
        CheckCasing(fn.Name, "function");
        CheckPredicateName(fn);
        CheckReturnIsDeclared(fn);
        CheckDoc(fn);

        if (fn.Body is null)
        {
            Error(fn.Name.Line, "A top-level function cannot be abstract.",
                  "Abstract members belong in a trait or a class.");
            return;
        }

        var inner = new Scope(scope, functionBoundary: true);
        foreach (var p in fn.Params)
        {
            if (p.Type is null)
                Error(p.Name.Line,
                      $"Parameter {p.Name.Lexeme} needs a type.",
                      "Types are inferred inside a function but written at its edges: "
                      + $"func {fn.Name.Lexeme}({p.Name.Lexeme}: Int) ...");

            CheckCasing(p.Name, "parameter");
            CheckDefault(p, inner);
            inner.Declare(p.Name.Lexeme, Resolve(p.Type), line: p.Name.Line);
        }

        CheckDefaultsComeLast(fn.Params);

        _returnTypes.Push((fn.Name.Lexeme, Resolve(fn.ReturnType)));
        int enclosingLoops = _loopDepth;
        _hiddenLoops += enclosingLoops;
        _loopDepth = 0;
        CheckBlock(fn.Body, inner);
        _loopDepth = enclosingLoops;
        _hiddenLoops -= enclosingLoops;
        _returnTypes.Pop();

        MustReturn(Resolve(fn.ReturnType), fn.Body, fn.Name.Lexeme, fn.Name.Line);
    }

    private void CheckBlock(List<Stmt> body, Scope scope)
    {
        CheckIndentation(body, _file);

        // An `if` with no else whose branch cannot fall out of the bottom makes everything
        // after it the else. So what the condition disproved is proved from there on, and
        // `if x == nothing { return }` narrows the rest of the block the way writing the
        // else out longhand already did.
        //
        // This is what the guard modifier is for — `return 0 if total == nothing` is the
        // shape §3.1 encourages — and without it the encouraged shape was the one that
        // lost narrowing.
        var current = scope;

        foreach (var stmt in body)
        {
            CheckStmt(stmt, current);

            if (stmt is not Stmt.If { Else: null } guard || !Leaves(guard.Then)) continue;

            var after = new Scope(current);
            foreach (var (name, type) in Refinements(guard.Condition, whenTrue: false, current))
                after.Declare(name, type);
            current = after;
        }
    }

    /// <summary>
    /// Whether every way out of this body returns a value. Separate from <see cref="Leaves"/>
    /// because they ask different questions: <c>break</c> leaves a block without returning
    /// from the function, so it settles narrowing and settles nothing here.
    ///
    /// Conservative in the direction that reports nothing: a loop that might run zero times
    /// promises nothing, but <c>while true</c> with no way out of it never falls through.
    /// </summary>
    private static bool Returns(List<Stmt> body) =>
        body.Count > 0 && body[^1] switch
        {
            // throw is not a return, but it is a way out — nobody receives the missing value.
            Stmt.Return r => r.Value is not null,
            Stmt.Throw => true,
            Stmt.If i => i.Else is not null && Returns(i.Then) && Returns(i.Else),
            Stmt.While w => IsAlwaysTrue(w.Condition) && !HasBreak(w.Body),
            Stmt.TryCatch t => Returns(t.Body) && t.Clauses.All(c => Returns(c.Body)),
            _ => false
        };

    private static bool IsAlwaysTrue(Expr condition) =>
        condition is Expr.Literal { Value: true };

    /// <summary>
    /// Whether a <c>break</c> can leave <em>this</em> loop. A nested loop's break is its
    /// own, and a block cannot break at all (§3.1), so neither is descended into.
    /// </summary>
    private static bool HasBreak(List<Stmt> body) =>
        body.Any(stmt => stmt switch
        {
            Stmt.Break => true,
            Stmt.If i => HasBreak(i.Then) || (i.Else is not null && HasBreak(i.Else)),
            Stmt.TryCatch t => HasBreak(t.Body) || t.Clauses.Any(c => HasBreak(c.Body)),
            _ => false
        });

    /// <summary>
    /// A body that promises a value has to produce one on every path out. Without this a
    /// function declared <c>: Int</c> could fall off its end and hand back nothing, which
    /// binds to a non-nullable Int and surfaces as an error somewhere else entirely.
    /// </summary>
    private void MustReturn(EmType returns, List<Stmt> body, string what, int line)
    {
        if (returns is EmType.Unknown || returns.Equals(EmType.Nothing)) return;
        if (Returns(body)) return;

        Error(line, $"{what} returns {returns.Show()}, but it can end without returning one.",
              "Every way out has to return a value. Add one at the end, or give the last "
              + "if an else that has one.");
    }

    /// <summary>
    /// Whether control cannot reach the bottom of this block. Conservative on purpose: a
    /// block that might fall through narrows nothing, which is the safe answer.
    /// </summary>
    private static bool Leaves(List<Stmt> body) =>
        body.Count > 0 && body[^1] switch
        {
            Stmt.Return or Stmt.Throw or Stmt.Break or Stmt.Continue => true,
            Stmt.If i => i.Else is not null && Leaves(i.Then) && Leaves(i.Else),
            _ => false
        };

    /// <summary>
    /// A second declaration of a name still visible in this function is almost always a
    /// student meaning to <em>change</em> the first. The message says that outright,
    /// because "already declared" alone does not explain the misunderstanding.
    /// </summary>
    private void CheckShadowing(Token name, Scope scope)
    {
        var existing = scope.FindInFunction(name.Lexeme);
        if (existing is null) return;

        Error(name.Line,
              existing.Line > 0
                  ? $"{name.Lexeme} is already declared on line {existing.Line}."
                  : $"{name.Lexeme} is already declared.",
              $"This makes a second {name.Lexeme}; it does not change the first. "
              + $"To change the existing one, drop the var: {name.Lexeme} = ...");
    }

    // ---- narrowing ------------------------------------------------------

    /// <summary>
    /// Names that some function or block assigns without declaring — a variable one call
    /// can change behind another's back.
    ///
    /// Narrowing proves what a variable holds at the moment of the check. If a call in
    /// between can reassign it, the proof expires and the checker was still trusting it:
    ///
    ///     var name: String? = "ada"
    ///     func clear() { name = nothing }
    ///     if name != nothing {
    ///         clear()
    ///         print(name.length)      # compiled, then crashed
    ///     }
    ///
    /// Kotlin refuses the same smart cast for the same reason. A variable a lambda merely
    /// declares for itself is not captured and stays narrowable — otherwise the rule would
    /// take away far more than it protects.
    /// </summary>
    private readonly HashSet<string> _capturedAndAssigned = [];

    private void FindCapturedAssignments(List<Stmt> program)
    {
        foreach (var stmt in program) Walk(stmt, visible: null);

        // `visible` is null at the top level, where an assignment is to a plain variable
        // and nothing is captured. Inside a function or block it holds the names declared
        // there, so an assignment to anything else reaches outward.
        void Walk(Stmt stmt, HashSet<string>? visible)
        {
            switch (stmt)
            {
                case Stmt.VarDecl v:
                    visible?.Add(v.Name.Lexeme);
                    if (v.Init is not null) WalkExpr(v.Init, visible);
                    if (v.Getter is not null) Enter(v.Getter, visible, []);
                    if (v.Setter is not null) Enter(v.Setter, visible, ["value"]);
                    break;

                case Stmt.Assign a:
                    if (visible is not null && a.Target is Expr.Variable target
                        && !visible.Contains(target.Name.Lexeme))
                        _capturedAndAssigned.Add(target.Name.Lexeme);
                    WalkExpr(a.Value, visible);
                    break;

                case Stmt.FuncDecl f when f.Body is not null:
                    Enter(f.Body, visible, [.. f.Params.Select(p => p.Name.Lexeme)]);
                    break;

                case Stmt.ConstructorDecl c:
                    Enter(c.Body, visible, [.. c.Params.Select(p => p.Name.Lexeme)]);
                    break;

                case Stmt.ClassDecl c:
                    foreach (var member in c.Members) Walk(member, visible);
                    foreach (var line in c.Initializer ?? []) Walk(line, visible);
                    break;

                case Stmt.If i:
                    WalkExpr(i.Condition, visible);
                    foreach (var s in i.Then) Walk(s, visible);
                    foreach (var s in i.Else ?? []) Walk(s, visible);
                    break;

                case Stmt.While w:
                    WalkExpr(w.Condition, visible);
                    foreach (var s in w.Body) Walk(s, visible);
                    break;

                case Stmt.For f:
                    WalkExpr(f.Iterable, visible);
                    visible?.Add(f.Variable.Lexeme);
                    foreach (var s in f.Body) Walk(s, visible);
                    break;

                case Stmt.TryCatch t:
                    foreach (var s in t.Body) Walk(s, visible);
                    foreach (var clause in t.Clauses)
                        foreach (var s in clause.Body) Walk(s, visible);
                    break;

                case Stmt.ExprStmt e: WalkExpr(e.Expression, visible); break;
                case Stmt.Return r when r.Value is not null: WalkExpr(r.Value, visible); break;
                case Stmt.Throw t: WalkExpr(t.Value, visible); break;
                case Stmt.Assert a: WalkExpr(a.Condition, visible); break;
            }
        }

        void Enter(List<Stmt> body, HashSet<string>? outer, IEnumerable<string> bound)
        {
            // A nested body sees what it declares plus what encloses it: assigning a name
            // the enclosing function declared is still a capture from this one's view, but
            // it is the outer scope's business, and it is recorded when that body is read.
            HashSet<string> inner = [.. bound];
            if (outer is not null) inner.UnionWith(outer);
            foreach (var s in body) Walk(s, inner);
        }

        void WalkExpr(Expr expr, HashSet<string>? visible)
        {
            switch (expr)
            {
                case Expr.Lambda l:
                    Enter(l.Body, visible, [.. l.Params.Select(p => p.Name.Lexeme)]);
                    break;

                case Expr.Call c:
                    WalkExpr(c.Callee, visible);
                    foreach (var arg in c.Args) WalkExpr(arg, visible);
                    if (c.Trailing is not null) WalkExpr(c.Trailing, visible);
                    break;

                case Expr.Binary b: WalkExpr(b.Left, visible); WalkExpr(b.Right, visible); break;
                case Expr.Logical l: WalkExpr(l.Left, visible); WalkExpr(l.Right, visible); break;
                case Expr.Unary u: WalkExpr(u.Right, visible); break;
                case Expr.Grouping g: WalkExpr(g.Inner, visible); break;
                case Expr.Get g: WalkExpr(g.Target, visible); break;
                case Expr.Index x: WalkExpr(x.Target, visible); WalkExpr(x.Position, visible); break;
                case Expr.RangeExpr r: WalkExpr(r.Start, visible); WalkExpr(r.End, visible); break;
                case Expr.ListLiteral l: foreach (var i in l.Items) WalkExpr(i, visible); break;
                case Expr.Interpolation p: foreach (var i in p.Parts) WalkExpr(i, visible); break;
                case Expr.IfExpr i:
                    WalkExpr(i.Condition, visible);
                    WalkExpr(i.Then, visible);
                    WalkExpr(i.Else, visible);
                    break;
                case Expr.DictLiteral d:
                    foreach (var e in d.Entries) { WalkExpr(e.Key, visible); WalkExpr(e.Value, visible); }
                    break;
            }
        }
    }

    /// <summary>
    /// What a condition proves about the variables in it. Handles the shapes a beginner
    /// actually writes — <c>x != nothing</c>, <c>x == nothing</c>, and those joined by
    /// <c>and</c>. Anything more elaborate simply narrows nothing, which is safe.
    /// </summary>
    private Dictionary<string, EmType> Refinements(Expr condition, bool whenTrue, Scope scope)
    {
        Dictionary<string, EmType> result = [];
        Collect(condition, whenTrue, result, scope, _capturedAndAssigned, Resolve);
        return result;

        static void Collect(
            Expr expr, bool whenTrue, Dictionary<string, EmType> into, Scope scope,
            HashSet<string> blocked, Func<TypeRef?, EmType> resolve)
        {
            switch (expr)
            {
                case Expr.Grouping g:
                    Collect(g.Inner, whenTrue, into, scope, blocked, resolve);
                    break;

                // `a and b` proves both when true.
                case Expr.Logical { Op.Type: TokenType.And } l when whenTrue:
                    Collect(l.Left, true, into, scope, blocked, resolve);
                    Collect(l.Right, true, into, scope, blocked, resolve);
                    break;

                case Expr.Unary { Op.Type: TokenType.Not } u:
                    Collect(u.Right, !whenTrue, into, scope, blocked, resolve);
                    break;

                // `x is Dog` proves what x holds, exactly as `x != nothing` does. Only in
                // the true branch: knowing a value is not a Dog says nothing about which
                // of the remaining types it is.
                case Expr.TypeTest { Value: Expr.Variable v } t when whenTrue:
                    if (!blocked.Contains(v.Name.Lexeme) && resolve(t.Type) is { } narrowed)
                        into[v.Name.Lexeme] = narrowed;
                    break;

                // Narrowing strips the ?, rather than widening to "could be anything".
                // Both let `maybe.length` through, which is all v0 originally needed — but
                // only the stripped type still knows it is a Weight, and an operator has to
                // find `add` on it. Any is the fallback for a name that is somehow not in
                // scope; the surrounding code will have reported that already.
                case Expr.Binary b when IsNothingTest(b, out var name, out bool isNotEqual):
                    // A variable some call can reassign is not narrowed: the check would
                    // still be believed after the call that undid it.
                    if (isNotEqual == whenTrue && !blocked.Contains(name))
                        into[name] = scope.Find(name)?.Type.Stripped ?? EmType.Any;
                    break;
            }
        }

        static bool IsNothingTest(Expr.Binary b, out string name, out bool isNotEqual)
        {
            name = "";
            isNotEqual = b.Op.Type == TokenType.NotEqual;
            if (b.Op.Type is not (TokenType.Equal or TokenType.NotEqual)) return false;

            if (b.Left is Expr.Variable v && b.Right is Expr.Literal { Value: null })
            { name = v.Name.Lexeme; return true; }

            if (b.Right is Expr.Variable v2 && b.Left is Expr.Literal { Value: null })
            { name = v2.Name.Lexeme; return true; }

            return false;
        }
    }

    /// <summary>
    /// <c>value is Dog</c>. Always a Bool, and always worth checking for the two shapes
    /// that mean the writer misunderstood something: a test that cannot fail, and a test
    /// that cannot pass. Both compile in C# and Java without comment, and both are bugs
    /// often enough to be worth naming here.
    /// </summary>
    /// <summary>The declared Error class, which the prelude always supplies.</summary>
    private ClassInfo? ErrorInfo => _classes.GetValueOrDefault(Prelude.ErrorType);

    /// <summary>Whether a type is Error or something a program derived from it.</summary>
    private bool IsErrorType(EmType type) =>
        type.Stripped is EmType.Obj o && ErrorInfo is { } root && Descends(o.Info, root);

    /// <summary>
    /// The catch clauses of one try. Each binds its name to the error it catches, so a
    /// typed clause hands the handler the real class and its fields — which is the whole
    /// reason to write the type down.
    ///
    /// Clauses are tried in source order, so one that could never run is reported here
    /// rather than left to be discovered by an error that mysteriously lands elsewhere.
    /// C# does the same, and for the same reason: an unreachable handler is always a
    /// mistake about which error goes first, never a deliberate choice.
    /// </summary>
    private void CheckCatchClauses(Stmt.TryCatch node, Scope scope)
    {
        List<(EmType Type, Token Name)> earlier = [];

        foreach (var clause in node.Clauses)
        {
            // No type written: this clause catches everything, which is what the short
            // form has always meant and what a program that does not care should write.
            var caught = clause.Type is null
                ? (ErrorInfo is { } root ? new EmType.Obj(root) : EmType.Any)
                : Resolve(clause.Type);

            if (clause.Type is not null && !IsErrorType(caught) && caught is not EmType.Unknown)
                Error(clause.Type.Name.Line,
                      $"{caught.Show()} is not an error, so nothing can throw one.",
                      $"A catch names {Prelude.ErrorType} or something that extends it:  "
                      + $"class {caught.Show()} extends {Prelude.ErrorType}");

            foreach (var (before, at) in earlier)
                if (Covers(before, caught))
                {
                    Warn(clause.Name.Line,
                         $"This catch can never run — the one on line {at.Line} "
                         + $"already handles {caught.Show()}.",
                         "Put the narrower error first, or remove this one.");
                    break;
                }

            earlier.Add((caught, clause.Name));

            var handler = new Scope(scope);
            handler.Declare(clause.Name.Lexeme, caught, line: clause.Name.Line);
            CheckBlock(clause.Body, handler);
        }
    }

    /// <summary>Whether an earlier clause already catches everything a later one would.</summary>
    private static bool Covers(EmType earlier, EmType later) =>
        earlier is EmType.Obj wide
        && (later is not EmType.Obj narrow || Descends(narrow.Info, wide.Info));

    private EmType TypeTestType(Expr.TypeTest test, Scope scope)
    {
        var value = TypeOf(test.Value, scope);
        var wanted = Resolve(test.Type);

        // A maybe is the ordinary receiver for this, and `x is Dog` answering false for
        // nothing is what makes it useful. So the question is asked of what is inside.
        var held = value.Stripped;

        if (wanted is EmType.Obj || held is EmType.Obj || held.Equals(EmType.Any))
        {
            if (held is EmType.Obj from && wanted is EmType.Obj to)
            {
                if (Descends(from.Info, to.Info) && !value.IsMaybe)
                    Warn(test.Keyword.Line,
                         $"This is always true: every {from.Info.Name} is "
                         + $"{Article(to.Info.Name).ToLowerInvariant()} {to.Info.Name}.",
                         "The check can go, and so can the branch it guards.");

                // A trait on either side is never impossible: some subclass of the static
                // type may well mix it in, and refusing the test would refuse the case it
                // exists for -- an Animal that turns out to be a Speaker.
                else if (!Descends(from.Info, to.Info) && !Descends(to.Info, from.Info)
                         && from.Info.Kind != TypeKind.Trait
                         && to.Info.Kind != TypeKind.Trait)
                    Error(test.Keyword.Line,
                          $"{from.Info.Name} can never be {to.Info.Name}.",
                          "Neither inherits from the other, so this is false for every "
                          + "value it could be given.");
            }

            return EmType.Bool;
        }

        // Built-in types are sealed and have no hierarchy, so the answer is decidable now
        // and the test is never the right tool. Saying which member answers the question
        // beats saying only that this one does not.
        Error(test.Keyword.Line,
              $"{held.Show()} is not a type this can ask about.",
              "is compares an object against a class or trait. A built-in type is already "
              + "known here, so there is nothing to ask.");
        return EmType.Bool;
    }

    /// <summary>
    /// <c>animal as Dog</c> — the downcast <c>is</c> cannot provide.
    ///
    /// <c>is</c> narrows a <em>name</em>, which is the common case and only the common
    /// case: a field, a list element, or any expression that is not a bare variable has
    /// nowhere for the narrowing to be recorded. This answers the same question as a
    /// value, and gives back <c>T?</c> so the miss goes through the machinery already
    /// built for it rather than a second convention invented here.
    ///
    /// Spelled as a keyword beside <c>is</c> rather than as a method taking a type
    /// argument, which is what it was first built as. That version put angle brackets
    /// into ordinary code to answer an ordinary question, and it was chosen for the
    /// compiler's convenience — it gave the new type-argument syntax something to test —
    /// which is not a reason a reader of the language should ever have to pay for.
    /// </summary>
    private EmType TypeCastType(Expr.TypeCast cast, Scope scope)
    {
        var value = TypeOf(cast.Value, scope);
        var wanted = Resolve(cast.Type);
        var held = value.Stripped;

        if (held is EmType.Obj from && wanted is EmType.Obj to
            && !Descends(from.Info, to.Info) && !Descends(to.Info, from.Info)
            && from.Info.Kind != TypeKind.Trait && to.Info.Kind != TypeKind.Trait)
            Error(cast.Keyword.Line,
                  $"{from.Info.Name} can never be {to.Info.Name}.",
                  "Neither inherits from the other, so this is nothing for every value "
                  + "it could be given.");

        else if (held is not EmType.Obj && !held.Equals(EmType.Any)
                 && held is not EmType.Unknown)
            Error(cast.Keyword.Line,
                  $"{held.Show()} is not a type this can ask about.",
                  "as looks inside an object for a narrower class or trait. A built-in "
                  + "type is already known here, so there is nothing to ask.");

        return EmType.Nullable(wanted);
    }

    /// <summary>
    /// Type arguments exist to call .NET's generic methods, which needs a backend Emerald
    /// does not have yet — so today every one of them is refused, and the message says
    /// what the syntax is for rather than only that it is not allowed here.
    ///
    /// The syntax parses anyway, deliberately. Someone reaching for interop early gets a
    /// sentence about the code generator instead of "unexpected '&lt;'".
    /// </summary>
    private void RefuseTypeArguments(Expr.Call c, Token name)
    {
        if (c.TypeArgs is null) return;

        Error(name.Line, $"{name.Lexeme} does not take a type in angle brackets.",
              "Angle brackets on a call are for .NET's generic methods, which wait on "
              + "the code generator. To ask what an object really is, Emerald has "
              + "`value is Dog` and `value as Dog`.");
    }

    /// <summary>Whether one class reaches another through its bases or its traits.</summary>
    private static bool Descends(ClassInfo from, ClassInfo to) =>
        from == to
        || from.Traits.Any(t => Descends(t, to))
        || (from.Base is { } up && Descends(up, to));

    // ---- expressions ----------------------------------------------------

    private EmType TypeOf(Expr expr, Scope scope) => expr switch
    {
        Expr.Literal l => LiteralType(l.Value),
        // Each #{...} holds a real expression and must be checked. Without this, errors
        // inside interpolation are invisible to the checker and surface at runtime.
        Expr.Interpolation s => CheckInterpolation(s, scope),
        Expr.Grouping g => TypeOf(g.Inner, scope),
        Expr.Variable v => VariableType(v, scope),
        Expr.RangeExpr r => RangeType(r, scope),
        Expr.ListLiteral a => ListLiteralType(a, scope),
        Expr.DictLiteral d => DictLiteralType(d, scope),
        Expr.Index ix => IndexType(ix, scope),
        Expr.Unary u => UnaryType(u, scope),
        Expr.Binary b => BinaryType(b, scope),
        Expr.TypeTest t => TypeTestType(t, scope),
        Expr.TypeCast t => TypeCastType(t, scope),
        Expr.Logical l => LogicalType(l, scope),
        Expr.IfExpr i => IfExprType(i, scope),
        Expr.Lambda l => LambdaType(l, scope),
        Expr.Get g => StaticOf(g.Target, g.Name) ?? OptionalMemberType(g, scope),
        Expr.Call c => CallType(c, scope),
        _ => EmType.Any
    };

    private EmType CheckInterpolation(Expr.Interpolation node, Scope scope)
    {
        foreach (var part in node.Parts) NotAFunction(TypeOf(part, scope), part);
        return EmType.String;
    }

    /// <summary>
    /// Refuses a function where a value is being displayed. Everywhere else a method value
    /// is checked against a declared shape, so a forgotten <c>()</c> is caught by the type
    /// it does not match — but <c>print</c> takes anything and interpolation displays
    /// anything, so those two would show <c>&lt;function&gt;</c> and say nothing. Since
    /// parens became required (§3.1) that is the mistake most likely to be made, so the
    /// two places that cannot catch it by type are made to catch it by name.
    /// </summary>
    private void NotAFunction(EmType type, Expr written)
    {
        if (type is not EmType.Func fn) return;

        string source = Source.Of(written);
        Error(LineOf(written),
              $"This shows {source} itself, not what it answers.",
              $"It is {fn.Show()}. Add parentheses to call it:  {source}()");
    }

    private static EmType LiteralType(object? value) => value switch
    {
        null => EmType.Nothing,
        bool => EmType.Bool,
        long => EmType.Int,
        double => EmType.Float,
        string => EmType.String,
        _ => EmType.Any
    };

    private EmType VariableType(Expr.Variable v, Scope scope)
    {
        var binding = scope.Find(v.Name.Lexeme);
        if (binding is not null) return binding.Type;

        Error(v.Name.Line, $"No variable named {v.Name.Lexeme}.", MistakenForAFunction(v.Name));
        return EmType.Any;
    }

    /// <summary>
    /// A name that is unknown as a global but known as a method — <c>round(x)</c> from
    /// someone whose last language had it as a function, where here it is <c>x.round</c>.
    /// A common enough beginner mistake that "declare it first" is worse than nothing: it
    /// is confidently wrong, and §3.6 says that sends a beginner somewhere false.
    /// </summary>
    private string MistakenForAFunction(Token name)
    {
        // super is bound like self — an ordinary name, present only where there is
        // something above to reach. "Declare it first: var super = ..." is the least
        // helpful thing that could be said to someone who wrote it.
        if (name.Lexeme == "super")
            return _currentType is { } inside
                ? $"{inside.Name} extends nothing and mixes in no traits, so there is nothing "
                  + "above it for super to reach."
                : "super means the class you extended, so it only has a meaning inside one.";

        // Inside a type, a bare name that is one of its own members is a missing receiver,
        // not an undeclared variable. `return contents` reads perfectly and is wrong, and
        // "declare it first" answers it by suggesting a second, unrelated variable — §3.6's
        // confidently-wrong case exactly.
        if (_currentType is { } here)
        {
            if (here.MemberNames().Contains(name.Lexeme))
                return $"{name.Lexeme} belongs to {here.Name}, so it is reached through "
                       + $"self:  self.{name.Lexeme}";

            if (here.StaticNames().Contains(name.Lexeme))
                return $"{name.Lexeme} belongs to {here.Name} itself, so it is reached "
                       + $"through the type:  {here.Name}.{name.Lexeme}";
        }

        // Every owner, from both sources. Naming only the first is worse than naming none:
        // `count(items)` answered with "Range has one" is true and points away from the
        // list the reader is actually holding.
        List<string> owners = [.. Signatures.TypesWithMethod(name.Lexeme)];

        if (Signatures.ListMethods.Contains(name.Lexeme)) owners.Add("List");
        if (Signatures.DictMethods.Contains(name.Lexeme)) owners.Add("Dictionary");
        if (Signatures.SetMethods.Contains(name.Lexeme)) owners.Add("Set");

        if (owners.Count == 0) return $"Declare it first: var {name.Lexeme} = ...";

        return $"{name.Lexeme} is a method here, not a function — reach it with a dot:  "
               + $"value.{name.Lexeme}\n"
               + $"  {Join(owners)} {(owners.Count == 1 ? "has" : "have")} one.";
    }

    private EmType RangeType(Expr.RangeExpr r, Scope scope)
    {
        Expect(TypeOf(r.Start, scope), EmType.Int, r.Start, "a range start");
        Expect(TypeOf(r.End, scope), EmType.Int, r.End, "a range end");

        // A range counts up, so one written the other way round holds nothing — and doing
        // nothing quietly is the failure §2.6 exists to catch. Only when both ends are
        // written out: `0..(n - 1)` has to stay silently empty, since that is the whole
        // reason the range is empty rather than reversing, and there the emptiness is the
        // answer rather than a mistake.
        if (ConstantInt(r.Start) is { } from && ConstantInt(r.End) is { } to && to < from)
            Error(LineOf(r.Start),
                  $"{from}..{to} is empty — a range counts up, never down.",
                  $"To count down:  {from}.downto({to})");

        return EmType.Range;
    }

    /// <summary>An integer written out, including a negated one. Null if it is computed.</summary>
    private static long? ConstantInt(Expr expr) => expr switch
    {
        Expr.Literal { Value: long n } => n,
        Expr.Unary { Op.Type: TokenType.Minus, Right: Expr.Literal { Value: long n } } => -n,
        _ => null
    };

    private EmType UnaryType(Expr.Unary u, Scope scope)
    {
        var operand = TypeOf(u.Right, scope);
        if (u.Op.Type == TokenType.Not)
        {
            Expect(operand, EmType.Bool, u.Right, "not");
            return EmType.Bool;
        }
        if (operand is not EmType.Unknown && !IsNumeric(operand))
            Error(u.Op.Line, $"Cannot negate {operand.Show()}.");
        return operand;
    }

    private EmType BinaryType(Expr.Binary b, Scope scope)
    {
        var left = TypeOf(b.Left, scope);
        var right = TypeOf(b.Right, scope);

        switch (b.Op.Type)
        {
            // == stays permitted on everything. It has to: narrowing is built on
            // `x != nothing` type-checking whatever x is. A class that mixes in Equatable
            // decides what sameness means; one that does not compares identity.
            case TokenType.Equal or TokenType.NotEqual:
                if (left is EmType.Obj) OperatorCall(b, left, right, Prelude.EqualsMethod);
                return EmType.Bool;

            case TokenType.Less or TokenType.Greater
                 or TokenType.LessEqual or TokenType.GreaterEqual:
                // Strings order lexicographically — the one comparison a beginner reaches
                // for that has nothing to do with arithmetic.
                if (left.Equals(EmType.String) && right.Equals(EmType.String))
                    return EmType.Bool;

                if (left is EmType.Obj)
                {
                    var result =
                        OperatorCall(b, left, right, Prelude.CompareMethod, Prelude.OrderedTrait);

                    // All four operators read the sign of one number, so a compare that
                    // hands back anything else makes every one of them wrong at once.
                    if (result is not EmType.Unknown && !EmType.Int.Accepts(result))
                        Error(b.Op.Line,
                              $"{left.Show()}.{Prelude.CompareMethod} returns "
                              + $"{result.Show()}, but ordering reads an Int.",
                              "Negative if self sorts first, zero if the two sort alike, "
                              + "positive if self sorts after.");

                    return EmType.Bool;
                }

                if (!IsNumeric(left) || !IsNumeric(right))
                    Error(b.Op.Line, $"Cannot compare {left.Show()} with {right.Show()}.");
                return EmType.Bool;

            // An arithmetic operator on a user type is a method call. This is checked
            // before string concatenation, so `point + "x"` is an error against
            // Point.add rather than quietly becoming text.
            case var op when left is EmType.Obj && Prelude.Operators.ContainsKey(op):
            {
                var (method, trait) = Prelude.Operators[op];
                return OperatorCall(b, left, right, method, trait);
            }

            case TokenType.Plus when left.Equals(EmType.String) || right.Equals(EmType.String):
                return EmType.String;

            // `/` always produces a Float, even on two Ints (§3.1).
            case TokenType.Slash when IsNumeric(left) && IsNumeric(right):
                return EmType.Float;

            // `//` and `**` keep Ints as Ints.
            case TokenType.SlashSlash when left.Equals(EmType.Int) && right.Equals(EmType.Int):
                return EmType.Int;
            case TokenType.StarStar when left.Equals(EmType.Int) && right.Equals(EmType.Int):
                return EmType.Int;

            default:
                if (!IsNumeric(left) || !IsNumeric(right))
                {
                    Error(b.Op.Line,
                          $"Cannot use {b.Op.Lexeme} on {left.Show()} and {right.Show()}.",
                          left.IsMaybe || right.IsMaybe
                              ? "Check the value against nothing first, or supply a fallback."
                              : null);
                    return EmType.Any;
                }
                return left.Equals(EmType.Float) || right.Equals(EmType.Float)
                    ? EmType.Float
                    : EmType.Int;
        }
    }

    /// <summary>
    /// An operator applied to a user type, resolved to the method it lowers to (§3.2).
    ///
    /// <paramref name="trait"/> is null only for <c>==</c>, where a missing method is not
    /// an error — a type that has not said what sameness means is compared by identity.
    /// Every other operator has to be earned by mixing in its trait.
    /// </summary>
    private EmType OperatorCall(
        Expr.Binary b, EmType left, EmType right, string method, string? trait = null)
    {
        var info = ((EmType.Obj)left).Info;
        var overloads = info.FindMethods(method);

        if (overloads.Count == 0)
        {
            if (trait is null) return EmType.Bool;

            string kind = info.Kind switch
            {
                TypeKind.Struct => "struct",
                TypeKind.Trait => "trait",
                _ => "class",
            };

            Error(b.Op.Line,
                  $"{left.Show()} does not define {b.Op.Lexeme}.",
                  $"Operators are methods here. Mix in {trait} and define {method}:  "
                  + $"{kind} {left.Show()} with {trait}",
                  topic: "operator-trait");
            return EmType.Any;
        }

        // The operand goes to the method as its argument, so the method's own parameter
        // type is what rejects `money + 5`. The trait cannot do this itself — it has no
        // way to say "the same type as whatever implements me".
        //
        // An overloaded one is resolved here like any other call, which is what lets a
        // vector add both another vector and a number.
        var fn = overloads.FirstOrDefault(
            f => f.Params.Count == 1 && f.Params[0].Accepts(right));

        if (fn is not null) return fn.Return;

        Error(b.Op.Line,
              $"{b.Op.Lexeme} cannot take {right.Show()} on the right of {left.Show()}.",
              overloads.Count == 1
                  ? $"{left.Show()}.{method} expects {overloads[0].Params.FirstOrDefault()?.Show() ?? "nothing"}."
                  : $"{left.Show()}.{method} has "
                    + string.Join(", and ", overloads.Select(
                        f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".");

        return overloads[0].Return;
    }

    private EmType LogicalType(Expr.Logical l, Scope scope)
    {
        Expect(TypeOf(l.Left, scope), EmType.Bool, l.Left, l.Op.Lexeme);

        // The right side of `and` sees what the left side proved.
        var inner = new Scope(scope);
        if (l.Op.Type == TokenType.And)
            foreach (var (name, type) in Refinements(l.Left, whenTrue: true, scope))
                inner.Declare(name, type);

        Expect(TypeOf(l.Right, inner), EmType.Bool, l.Right, l.Op.Lexeme);
        return EmType.Bool;
    }

    private EmType IfExprType(Expr.IfExpr i, Scope scope)
    {
        Expect(TypeOf(i.Condition, scope), EmType.Bool, i.Condition, "an if condition");

        var thenScope = new Scope(scope);
        foreach (var (name, type) in Refinements(i.Condition, true, scope)) thenScope.Declare(name, type);
        var elseScope = new Scope(scope);
        foreach (var (name, type) in Refinements(i.Condition, false, scope)) elseScope.Declare(name, type);

        var a = TypeOf(i.Then, thenScope);
        var b = TypeOf(i.Else, elseScope);

        // The same rule a list literal uses, and for the same reasons: `nothing` in one
        // branch makes the answer optional rather than a clash, and two classes meet at a
        // shared base. This had its own copy of the first half and neither of those.
        if (CommonType(a, b) is { } common) return common;

        Error(LineOf(i.Condition),
              $"The then branch gives {a.Show()} but the else branch gives {b.Show()}.",
              "Both branches of an if expression must produce the same type.");
        return EmType.Any;
    }

    private EmType LambdaType(Expr.Lambda l, Scope scope, EmType? paramHint = null,
                             EmType.Func? shape = null,
                             int? supplies = null, string? given = null)
    {
        if (supplies is { } handed && given is { } by) CheckBlockArity(l, handed, by);

        var inner = new Scope(scope, functionBoundary: true);

        // What each parameter is: written down if the writer said so, otherwise taken from
        // the shape the receiving function declared, otherwise from a single hint — which
        // is what a list method gives, since every parameter of `map`'s block is one
        // element. Nothing to go on leaves it open rather than guessing.
        List<EmType> parameters = [];
        for (int i = 0; i < l.Params.Count; i++)
        {
            var p = l.Params[i];
            parameters.Add(
                p.Type is not null ? Resolve(p.Type)
                : shape is not null && i < shape.Params.Count ? shape.Params[i]
                : paramHint ?? EmType.Any);

            inner.Declare(p.Name.Lexeme, parameters[i]);
        }

        // A one-expression body is the lambda's value (§3.2).
        if (l.Body is [Stmt.ExprStmt only])
            return new EmType.Func(parameters, TypeOf(only.Expression, inner));

        // A block body has no single expression to read a type from, so the type being
        // asked for is the only thing that can say what its returns must be. Without it a
        // lambda that plainly hands back an Int was typed func(): Unknown -- and since an
        // unknown no longer satisfies a declared type, `var f: func(): Int = { ... }` with
        // a return in it was rejected outright, saying it had been given a func() that
        // gives nothing. Taking the wanted type also starts checking the returns against
        // something, which nothing was doing: Any accepted whatever came back.
        EmType wanted = shape?.Return ?? EmType.Any;

        _returnTypes.Push(("this block", wanted));
        int enclosingLoops = _loopDepth;
        _hiddenLoops += enclosingLoops;
        _loopDepth = 0;
        CheckBlock(l.Body, inner);
        _loopDepth = enclosingLoops;
        _hiddenLoops -= enclosingLoops;
        _returnTypes.Pop();

        // §3.2 promised this and did not have it: a block that never returns a value has
        // none to give. Calling it Any made `map { n => print(n) }` a list of nothings
        // that nothing complained about, which is the silent nothing the row ruled out.
        return new EmType.Func(parameters,
                               ReturnsAValue(l.Body) ? wanted : EmType.Nothing);
    }

    /// <summary>
    /// Whether any way out of this body carries a value. Nested lambdas are not descended
    /// into, since a return inside one belongs to it (§3.2).
    /// </summary>
    private static bool ReturnsAValue(List<Stmt> body) =>
        body.Any(stmt => stmt switch
        {
            Stmt.Return r => r.Value is not null,
            Stmt.If i => ReturnsAValue(i.Then) || (i.Else is not null && ReturnsAValue(i.Else)),
            Stmt.While w => ReturnsAValue(w.Body),
            Stmt.For f => ReturnsAValue(f.Body),
            Stmt.TryCatch t => ReturnsAValue(t.Body)
                               || t.Clauses.Any(c => ReturnsAValue(c.Body)),
            _ => false
        });

    /// <summary>
    /// A block cannot name more than it is handed. Naming fewer is ordinary — ignoring an
    /// argument is allowed everywhere — but the extra names could only ever be nothing,
    /// and they were silently bound to the element type as though they held one.
    /// </summary>
    private void CheckBlockArity(Expr.Lambda block, int supplied, string given)
    {
        if (block.Params.Count <= supplied) return;

        Error(block.Params[supplied].Name.Line,
              $"{given} hands its block {Amount(supplied)}, but this one names "
              + $"{block.Params.Count}.",
              supplied == 1
                  ? $"Name one:  {given} {{ {block.Params[0].Name.Lexeme} => ... }}"
                  : null);
    }

    private static string Amount(int n) => n == 1 ? "1 value" : $"{n} values";

    /// <summary>
    /// <c>Dog.from_shelter_id(42)</c> — a type name on the left means a type-level member.
    /// Returns null when the target is not a class name, so ordinary member access
    /// continues normally.
    /// </summary>
    /// <summary>
    /// A member whose name begins with <c>_</c> belongs to its type and to anything that
    /// extends it (§3.2). Checked at the <em>use</em> site, which is the reason visibility
    /// lives in the name at all: a reader sees it where the call is written, without
    /// going to look the declaration up.
    /// </summary>
    private void CheckVisibility(ClassInfo owner, Token name)
    {
        if (!name.Lexeme.StartsWith('_')) return;
        if (_currentType is { } here && here.IsSubclassOf(owner)) return;

        // Mirrored types follow a foreign API's naming, and .NET does use a leading
        // underscore for names it means to be public. Emerald's rule cannot reach back
        // and rename them, so it does not claim them either.
        if (owner.Mirrors) return;

        Error(name.Line,
              $"{name.Lexeme} belongs to {owner.Name} — that is what the _ says.",
              $"A name starting with _ can be used inside {owner.Name}, and inside any "
              + $"class that extends it. Drop the _ to let the rest of the program use it.");
    }

    private EmType? StaticOf(Expr target, Token name)
    {
        if (target is not Expr.Variable v) return null;
        if (!_classes.TryGetValue(v.Name.Lexeme, out var info)) return null;

        CheckVisibility(info, name);

        if (info.FindStatic(name.Lexeme) is { } found) return found;

        Error(name.Line, $"No class member named {name.Lexeme} on {info.Name}.",
              info.FindMethod(name.Lexeme) is not null
                  ? $"{name.Lexeme} belongs to an instance — call it on a {info.Name} value."
                  : Suggest(name.Lexeme, info.StaticNames()));
        return EmType.Any;
    }

    /// <summary>
    /// The <c>?.</c> access whose receiver is being typed right now, if there is one.
    /// Only <see cref="PredicateSwallowed"/> reads it, to recognize the one shape the
    /// scanner's rule gets wrong for a reader: <c>n.even?.to_string()</c>, where the ? was
    /// meant to end the name and was taken as the operator. Rarer than it was — with
    /// parentheses required (§3.1) the correct spelling has no <c>?.</c> in it at all,
    /// since <c>n.even?().to_string()</c> puts a <c>)</c> between the two marks.
    /// </summary>
    private Expr.Get? _optionalDot;

    /// <summary>
    /// The variable a member access was written on, if it was written on one. Read only by
    /// the maybe diagnostic, to tell "you have not checked this" apart from "you checked it
    /// and the check does not hold here".
    /// </summary>
    private string? _lastReceiverName;

    /// <summary>Types a <c>?.</c>'s receiver, remembering that it is one.</summary>
    private EmType ReceiverType(Expr.Get g, Scope scope)
    {
        var previous = _optionalDot;
        _optionalDot = g.Optional ? g : null;
        try { return TypeOf(g.Target, scope); }
        finally
        {
            _optionalDot = previous;
            _lastReceiverName = g.Target is Expr.Variable v ? v.Name.Lexeme : null;
        }
    }

    /// <summary>
    /// Whether the name that just failed to resolve is a predicate the <c>?.</c> rule ate
    /// — <c>even</c> looked up because <c>even?.</c> was written. Says so plainly, since
    /// "did you mean even??" answers a question nobody asked.
    /// </summary>
    private string? PredicateSwallowed(Token name, IEnumerable<string> members) =>
        _optionalDot is { Target: Expr.Get inner } outer
        && ReferenceEquals(name, inner.Name)
        && members.Contains(name.Lexeme + "?")
            ? $"The ? in {name.Lexeme}? is part of its name, so a dot cannot follow it. "
              + "Its parentheses separate the two:  "
              + $"{Source.Of(inner)}?().{outer.Name.Lexeme}()"
            : null;

    /// <summary>A member read, with <c>?.</c> handled if that is how it was written.</summary>
    private EmType OptionalMemberType(Expr.Get g, Scope scope, EmType? wanted = null)
    {
        var receiver = ReceiverType(g, scope);

        if (!g.Optional) return MemberType(receiver, g.Name, scope, wanted, g);

        return CheckedOptional(receiver, g)
            ? EmType.Nullable(MemberType(receiver.Stripped, g.Name, scope, wanted, g))
            : MemberType(receiver, g.Name, scope, wanted, g);
    }

    /// <summary>
    /// Whether a <c>?.</c> has something to ask. On a type that is never nothing it is
    /// noise that reads as caution, and the habit of writing it everywhere is what makes
    /// the operator stop carrying information — so it is refused rather than ignored.
    ///
    /// Returns whether to go on treating the access as optional.
    /// </summary>
    private bool CheckedOptional(EmType receiver, Expr.Get g)
    {
        if (receiver.IsMaybe || receiver is EmType.Unknown) return true;

        Error(g.Name.Line,
              $"{receiver.Show()} is never nothing, so ?. has nothing to check.",
              $"Write a plain dot:  .{g.Name.Lexeme}");

        return false;
    }

    /// <summary>
    /// A member read — no parentheses were written. Since every call has them (§3.1),
    /// this yields a field, a property, or the method <em>itself</em>; it never runs one.
    /// </summary>
    private EmType MemberType(
        EmType receiver, Token name, Scope scope,
        EmType? wanted = null, Expr.Get? written = null)
    {
        if (receiver is EmType.Unknown) return EmType.Any;

        // Every value answers this, so it is settled before any receiver-specific path --
        // including on a T?, since the value that surprised you is the one you ask about.
        if (name.Lexeme == Signatures.TypeNameMethod)
            return new EmType.Func([], EmType.String, 0);

        if (receiver is EmType.Prim { Name: "Kernel" })
        {
            if (!Kernel.TryGetValue(name.Lexeme, out var fn))
            {
                Error(name.Line, $"No function named {name.Lexeme} on Kernel.",
                      Suggest(name.Lexeme, Kernel.Keys));
                return EmType.Any;
            }

            return fn;
        }

        // The built-ins expose no properties (§3.1), so every member of one is a method
        // and reading it without parentheses is the missing-parens mistake.
        if (receiver is EmType.Lst or EmType.Dict or EmType.SetOf)
            return BuiltinRead(receiver, name);

        // .or and .must are the two things you are *supposed* to ask of a maybe, so they
        // have to be reachable before the guard below rejects everything else (§3.2).
        if (receiver.IsMaybe && name.Lexeme is "or" or "must")
            return receiver.Stripped;

        // Named .value() until it was renamed. The old name is the obvious thing to reach
        // for, and §3.6's suggestion table exists for exactly that.
        if (receiver.IsMaybe && name.Lexeme == "value")
        {
            Error(name.Line,
                  $"There is no .value on {receiver.Show()} — the name is .must.",
                  "must says the value is there and fails loudly when it is not:  "
                  + "count.must()\n  For a fallback instead, use .or(0)");
            return receiver.Stripped;
        }

        // The payoff of non-nullable-by-default: reaching through a maybe is an error
        // here, not a crash later (§3.2).
        if (receiver.IsMaybe)
        {
            // Telling someone to check it first, when the check is on the line above and
            // was refused because a call can undo it, is the worst version of this message.
            string hint = _lastReceiverName is { } held && _capturedAndAssigned.Contains(held)
                ? $"Checking {held} does not settle it here: a function assigns {held}, so "
                  + "it could have changed in between. Copy it first and check the copy, "
                  + $"which nothing else can reach:\n"
                  + $"var it = {held}\n"
                  + $"if it != nothing {{ ... }}"
                : $"{Article(receiver.Show())} {receiver.Show()} holds either "
                  + $"{Article(receiver.Stripped.Show()).ToLowerInvariant()} "
                  + $"{receiver.Stripped.Show()} or nothing. "
                  + "Check it first, or supply a fallback with .or(...)";

            Error(name.Line,
                  $"This is {receiver.Show()}, not {receiver.Stripped.Show()}, so {name.Lexeme} may not exist.",
                  hint,
                  topic: "maybe");
            return EmType.Any;
        }

        // An enum value carries a name and nothing else. Checked before the class path,
        // since an enum has no fields or methods of its own to find.
        if (receiver is EmType.Obj { Info.Kind: TypeKind.Enum } enumValue)
        {
            // .name is the value's own data, so it is read; .to_string is a method, so
            // naming it without parentheses hands back the method itself (§3.1).
            if (name.Lexeme == "name") return EmType.String;
            if (name.Lexeme == "to_string") return new EmType.Func([], EmType.String, 0);

            Error(name.Line,
                  $"No member named {name.Lexeme} on {enumValue.Info.Name}.",
                  enumValue.Info.StaticFields.ContainsKey(name.Lexeme)
                      ? $"{name.Lexeme} is one of {enumValue.Info.Name}'s values — "
                        + $"reach it on the type:  {enumValue.Info.Name}.{name.Lexeme}"
                      : "An enum value has .name, and compares with == against another "
                        + "of its own values.");
            return EmType.Any;
        }

        // A user class: fields and methods, walking the base chain exactly as EmClass does.
        if (receiver is EmType.Obj obj)
        {
            CheckVisibility(obj.Info, name);
            if (obj.Info.FindField(name.Lexeme) is { } fieldType) return fieldType;
            if (obj.Info.FindMethods(name.Lexeme) is { Count: > 0 } overloads)
                return MethodValue(overloads, obj.Info.Name, name, wanted, written);

            Error(name.Line, $"No member named {name.Lexeme} on {obj.Info.Name}.",
                  PredicateSwallowed(name, obj.Info.MemberNames())
                      ?? Suggest(name.Lexeme, obj.Info.MemberNames()));
            return EmType.Any;
        }

        return BuiltinRead(receiver, name);
    }

    /// <summary>
    /// Reading a built-in member without parentheses. There are no built-in properties
    /// (§3.1), so either the name exists and the parentheses are missing, or it does not
    /// exist at all — and those are different messages.
    /// </summary>
    private EmType BuiltinRead(EmType receiver, Token name)
    {
        if (Signatures.MethodsOn(receiver).Contains(name.Lexeme))
        {
            if (BuiltinShape(receiver, name.Lexeme) is { } shape) return shape;

            // The one built-in method that cannot be named without calling it, and the
            // reason is a rule rather than a list: its type depends on the block. What
            // `map` gives back is whatever the block gives back, so there is no shape to
            // write down until a block is written.
            Error(name.Line,
                  $"{receiver.Show()}.{name.Lexeme} takes a block, so naming it on its "
                  + "own does not say what it answers.",
                  $"Call it:  {name.Lexeme} {{ ... }}\n"
                  + "Or, to pass the whole thing along, wrap it in a block of your own:  "
                  + $"{{ ... {name.Lexeme} {{ ... }} }}");
            return EmType.Any;
        }

        Error(name.Line, $"No method named {name.Lexeme} on {receiver.Show()}.",
              LeftOverFallback(name, receiver)
                  ?? PredicateSwallowed(name, Signatures.MethodsOn(receiver))
                  ?? Suggest(name.Lexeme, Signatures.MethodsOn(receiver)));
        return EmType.Any;
    }

    /// <summary>
    /// <c>.or</c> and <c>.must</c> belong to <c>T?</c>, so meeting one on a plain <c>T</c>
    /// almost always means the value was checked already and the fallback is left from
    /// before the check. Saying a method is missing hides what actually changed.
    /// </summary>
    private static string? LeftOverFallback(Token name, EmType receiver) =>
        name.Lexeme is "or" or "must"
            ? $"{name.Lexeme} belongs to an optional. This is {receiver.Show()}, which "
              + "always holds a value, so the fallback can go."
            : null;

    /// <summary>
    /// The type of a built-in method named without parentheses, or null if it takes a
    /// block. §3.7's table records what a container method gives back and not what it
    /// takes, so the containers are answered here where the element, key and value types
    /// are known — the same place their arguments are already checked.
    /// </summary>
    private EmType? BuiltinShape(EmType receiver, string method) => receiver switch
    {
        EmType.Lst list => ListShape(list, method),
        EmType.Dict dict => DictShape(dict, method),
        EmType.SetOf set => SetShape(set, method),

        _ => Signatures.SignatureOf(receiver, method) is { WantsBlock: false } signature
            ? new EmType.Func([.. signature.Takes], signature.Returns,
                              signature.Takes.Length)
            : null,
    };

    private static EmType? Shape(EmType returns, params EmType[] takes) =>
        new EmType.Func([.. takes], returns, takes.Length);

    private EmType? ListShape(EmType.Lst list, string method)
    {
        EmType element = list.Element;
        return method switch
        {
            "count" or "index_of" or "sum" => method == "index_of"
                ? Shape(EmType.Int, element)
                : Shape(EmType.Int),
            "empty?" => Shape(EmType.Bool),
            "contains?" => Shape(EmType.Bool, element),
            "first" or "last" or "min" or "max" => Shape(EmType.Nullable(element)),
            "join" => Shape(EmType.String, EmType.String),
            "sort" or "reverse" => Shape(list),
            "add" => Shape(EmType.Nothing, element),
            "remove" => Shape(EmType.Nothing, element),
            "remove_at" => Shape(EmType.Nothing, EmType.Int),
            "clear" => Shape(EmType.Nothing),
            "to_set" => Shape(Setify(list, null)),
            _ => null,          // each, map, filter, reject, find, any?, all?, sort_by, reduce
        };
    }

    private static EmType? DictShape(EmType.Dict dict, string method) => method switch
    {
        "count" => Shape(EmType.Int),
        "empty?" => Shape(EmType.Bool),
        "has_key?" => Shape(EmType.Bool, dict.Key),
        "has_value?" => Shape(EmType.Bool, dict.Value),
        "keys" => Shape(new EmType.Lst(dict.Key)),
        "values" => Shape(new EmType.Lst(dict.Value)),
        "get" => Shape(EmType.Nullable(dict.Value), dict.Key),
        "set" => Shape(EmType.Nothing, dict.Key, dict.Value),
        "remove" => Shape(EmType.Nothing, dict.Key),
        "clear" => Shape(EmType.Nothing),
        _ => null,              // each
    };

    private static EmType? SetShape(EmType.SetOf set, string method) => method switch
    {
        "count" => Shape(EmType.Int),
        "empty?" => Shape(EmType.Bool),
        "contains?" => Shape(EmType.Bool, set.Element),
        "add" or "remove" => Shape(EmType.Nothing, set.Element),
        "clear" => Shape(EmType.Nothing),
        "to_list" => Shape(new EmType.Lst(set.Element)),
        "union" or "intersect" or "difference" => Shape(set, set),
        "subset_of?" => Shape(EmType.Bool, set),
        _ => null,              // each
    };

    /// <summary>
    /// <c>rex.speak</c> — the method itself, receiver attached. One overload is the whole
    /// answer; several are only resolvable against an expected shape, since a bare name
    /// carries no arguments to choose by.
    /// </summary>
    private EmType MethodValue(
        List<EmType.Func> overloads, string owner, Token name, EmType? wanted,
        Expr.Get? written)
    {
        if (overloads.Count == 1) return overloads[0];

        if (wanted is EmType.Func shape
            && overloads.Where(f => Answers(f, shape)).ToList() is { Count: 1 } single)
            return single[0];

        Error(name.Line,
              $"{owner}.{name.Lexeme} has {overloads.Count} versions, so it is not clear "
              + "which one this names.",
              "It has " + string.Join(", and ", overloads.Select(
                  f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})"))
              + ".\nSay which by writing the type it should have:  "
              + $"var f: {overloads[0].Show()} = "
              + (written is null ? name.Lexeme : Source.Of(written)));
        return EmType.Any;
    }

    private EmType CallType(Expr.Call c, Scope scope)
    {
        // Method calls resolve the receiver first, because a list method's block
        // parameter is typed from the element type — that is the contextual inference
        // that makes `numbers.map { x => x * 2 }` know what x is.
        if (c.Callee is Expr.Get get)
        {
            // Static call: Dog.from_shelter_id(42)
            if (StaticOf(get.Target, get.Name) is { } staticResult)
            {
                List<EmType> staticArgs = [.. c.Args.Select(arg => TypeOf(arg, scope))];
                if (c.Trailing is not null) TypeOf(c.Trailing, scope);

                if (get.Target is Expr.Variable owner
                    && _classes.TryGetValue(owner.Name.Lexeme, out var ownerInfo)
                    && ownerInfo.FindStaticMethods(get.Name.Lexeme) is { Count: > 0 } statics)
                {
                    string what = $"{ownerInfo.Name}.{get.Name.Lexeme}";

                    if (statics.Count == 1)
                        return CheckArguments(statics[0], c, staticArgs, what, get.Name.Line);

                    int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);
                    var chosen = statics.FirstOrDefault(f => Fits(f, supplied, staticArgs));
                    if (chosen is not null) return chosen.Return;

                    Error(get.Name.Line,
                          $"No version of {what} takes "
                          + (staticArgs.Count == 0
                                ? "no arguments."
                                : $"({string.Join(", ", staticArgs.Select(t => t.Show()))})."),
                          "It has " + string.Join(", and ", statics.Select(
                              f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".");
                    return EmType.Any;
                }

                return staticResult;
            }

            var receiver = ReceiverType(get, scope);

            // ?. reads through the ? and puts it back on the answer: the call happens only
            // when the receiver is there, so what comes out might not be either.
            if (get.Optional)
                return CheckedOptional(receiver, get)
                    ? EmType.Nullable(MemberCallType(receiver.Stripped, c, get, scope))
                    : MemberCallType(receiver, c, get, scope);

            return MemberCallType(receiver, c, get, scope);
        }

        // The trailing block is deliberately left untyped here: NonMemberCallType types it
        // once the callee is known, so its parameters can be inferred from the shape the
        // callee asks for.
        List<EmType> given = [.. c.Args.Select(arg => TypeOf(arg, scope))];
        return NonMemberCallType(c, given, scope);
    }

    /// <summary>Types an expression, offering a lambda the shape it is expected to have.</summary>
    private EmType TypeOf(Expr expr, Scope scope, EmType? wanted) => expr switch
    {
        Expr.Lambda l when wanted is EmType.Func shape => LambdaType(l, scope, shape: shape),

        // Which overload `rex.speak` names cannot be read off the site, so the expected
        // type decides (§3.1). Only a member read needs this: a call picks its overload
        // from the arguments, which are written right there.
        Expr.Get g when wanted is EmType.Func && StaticOf(g.Target, g.Name) is null
            => OptionalMemberType(g, scope, wanted),

        _ => TypeOf(expr, scope),
    };

    /// <summary>
    /// A call whose receiver is already resolved. Split out so <c>?.</c> can hand it the
    /// stripped type and wrap what comes back, without every exit here having to know.
    /// </summary>
    private EmType MemberCallType(EmType receiver, Expr.Call c, Expr.Get get, Scope scope)
    {
        {
            // Asked of anything, including a maybe — the value that surprised you is the
            // one you ask about, and refusing it on a T? would refuse the common case.
            if (get.Name.Lexeme == Signatures.TypeNameMethod && c.Args.Count == 0)
                return EmType.String;

            // Nothing in Emerald's own surface takes type arguments, so a stray pair is
            // caught once here rather than ignored by every path that does not look.
            RefuseTypeArguments(c, get.Name);

            if (receiver is EmType.PairOf pair)
                return get.Name.Lexeme switch
                {
                    "first" => pair.First,
                    "second" => pair.Second,
                    "to_string" => EmType.String,
                    _ => NoSuchMember(get.Name, pair.Show(), ["first", "second", "to_string"]),
                };

            if (receiver is EmType.Lst list) return ListCallType(list, c, get.Name, scope);
            if (receiver is EmType.Dict dict) return DictMemberType(dict, get.Name, c, scope);
            if (receiver is EmType.SetOf set) return SetMemberType(set, get.Name, c, scope);

            // A range walks whole numbers, so its shared members are typed from Int. The
            // rest of it -- contains?, first, last -- stays in the signature table, which
            // is enough for members whose answer does not depend on a block.
            if (receiver.Equals(EmType.Range) && Builtins.Shared.Contains(get.Name.Lexeme))
                return IterableMemberType(EmType.Range, [EmType.Int], get.Name, c, scope);

            List<EmType> args = [.. c.Args.Select(arg => TypeOf(arg, scope))];

            // A method that declares a block parameter gives the block its shape, exactly
            // as a plain function does — so it is typed after the method is known.
            //
            // It joins the argument list only for a user-declared method, where a block is
            // an ordinary last argument. A built-in counts the two apart on purpose:
            // `5.times { }` passes no arguments and one block, and CheckBuiltinCall says
            // "does not take a block" precisely because it can still tell them apart.
            EmType? blockType = null;
            if (c.Trailing is not null)
            {
                var wanted = receiver is EmType.Obj holder
                    ? Wanted(holder.Info.FindMethods(get.Name.Lexeme) is [var only]
                                 ? only
                                 : EmType.Any,
                             args.Count)
                    : null;

                blockType = TypeOf(c.Trailing, scope, wanted);
            }

            // A user-declared method carries real parameter types. A built-in one lives in
            // the return-type table, which records what it gives back and not what it
            // takes, so there is nothing there to check a call against.
            if (receiver is EmType.Obj obj
                && obj.Info.FindMethods(get.Name.Lexeme) is { Count: > 0 } candidates)
            {
                if (blockType is not null) args.Add(blockType);

                CheckVisibility(obj.Info, get.Name);
                string what = $"{obj.Info.Name}.{get.Name.Lexeme}";

                // Recorded even with nothing to choose between. The static type is what
                // decides: through a Base reference the only candidate is Base's, while
                // the object underneath may be a Sub carrying an inherited set with a
                // more specific version the interpreter would otherwise reach for.
                if (candidates.Count == 1)
                {
                    Choose(c, candidates[0]);
                    return CheckArguments(candidates[0], c, args, what, get.Name.Line,
                                          obj.Info, get.Name.Lexeme);
                }

                int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);
                var chosen = candidates.FirstOrDefault(f => Fits(f, supplied, args));
                if (chosen is not null)
                {
                    Choose(c, chosen);
                    return chosen.Return;
                }

                string has = "It has " + string.Join(", and ", candidates.Select(
                    f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".";

                Error(get.Name.Line,
                      $"No version of {what} takes "
                      + (args.Count == 0
                            ? "no arguments."
                            : $"({string.Join(", ", args.Select(t => t.Show()))})."),
                      has);
                return EmType.Any;
            }

            // .or and .must are intrinsics rather than entries in a signature table, so
            // nothing was checking them: `count.or()` reached a runtime crash when the
            // value was missing, and `count.or("none")` on an Int? was accepted while
            // giving back a String from an expression the checker called Int.
            if (receiver.IsMaybe && get.Name.Lexeme is "or" or "must")
                return CheckFallback(receiver, c, args, get.Name);

            // A field holding a function, called: `button.on_click()`. It is not a method,
            // so the method lookup above passed it by, and without this the call went
            // unchecked entirely.
            if (receiver is EmType.Obj held
                && held.Info.FindMethods(get.Name.Lexeme).Count == 0
                && held.Info.FindField(get.Name.Lexeme) is EmType.Func field)
            {
                CheckVisibility(held.Info, get.Name);
                if (blockType is not null) args.Add(blockType);
                return CheckArguments(field, c, args,
                                      $"{held.Info.Name}.{get.Name.Lexeme}", get.Name.Line);
            }

            // An enum value has one property and one method. Calling the method is
            // ordinary; calling the property is the same mistake as calling a field.
            if (receiver is EmType.Obj { Info.Kind: TypeKind.Enum }
                && get.Name.Lexeme == "to_string")
                return EmType.String;

            if (receiver is EmType.Obj { Info.Kind: TypeKind.Enum } value2
                && get.Name.Lexeme == "name")
            {
                Error(get.Name.Line,
                      $"{value2.Info.Name}.name is String, not a method.",
                      "It is read without parentheses:  "
                      + $"{Source.Of(get.Target)}.name");
                return EmType.String;
            }

            // A field or property, reached with parentheses. The two are deliberately
            // indistinguishable here — that interchange is what survived the removal of
            // optional parens (§3.1) — so the message names neither, only that this is a
            // value the object has rather than something it does.
            if (receiver is EmType.Obj value
                && value.Info.FindMethods(get.Name.Lexeme).Count == 0
                && value.Info.FindField(get.Name.Lexeme) is { } plain)
            {
                CheckVisibility(value.Info, get.Name);
                Error(get.Name.Line,
                      $"{value.Info.Name}.{get.Name.Lexeme} is {plain.Show()}, not a method.",
                      "It is read without parentheses:  "
                      + $"{Source.Of(get.Target)}.{get.Name.Lexeme}");
                return plain;
            }

            // Kernel goes through the very signatures the bare names use, so `print(x)`
            // and `Kernel.print(x)` cannot be checked differently.
            if (receiver is EmType.Prim { Name: "Kernel" })
            {
                if (get.Name.Lexeme == "print")
                    foreach (var written in c.Args) NotAFunction(TypeOf(written, scope), written);

                return Kernel.TryGetValue(get.Name.Lexeme, out var kernel)
                    ? CheckArguments(kernel, c, args, $"Kernel.{get.Name.Lexeme}", get.Name.Line)
                    : MemberType(receiver, get.Name, scope);
            }

            // A built-in method is found by head type, and a head reads through a ? —
            // List<Int> and List<Int>? both look up as List. The container paths match on
            // the concrete type and so noticed anyway, but the primitives were looked up
            // by that name alone: `count.abs()` on an Int? found Int's abs and the maybe
            // went unremarked. That skipped the check the language exists for on exactly
            // the types most maybes have, since to_int_maybe, find and a dictionary lookup
            // nearly all give back a primitive one.
            //
            // .or and .must are what you are supposed to ask of a maybe, so they go on.
            if (receiver.IsMaybe && get.Name.Lexeme is not ("or" or "must"))
                return MemberType(receiver, get.Name, scope);

            // A built-in has a signature now too, so the standard library is checked the
            // same way the program is.
            if (Signatures.SignatureOf(receiver, get.Name.Lexeme) is { } builtin)
                return CheckBuiltinCall(builtin, c, args, receiver, get.Name);

            return MemberType(receiver, get.Name, scope);
        }
    }

    /// <summary>A call that is not a method call: a constructor, a name, an expression.</summary>
    /// <summary>
    /// The shape a callee declares for the argument in this position, if it declares one.
    /// Used only as a hint: a wrong guess costs nothing, because the argument is checked
    /// against the real signature immediately afterwards.
    /// </summary>
    /// <summary>
    /// <c>super(...)</c>. Three things have to hold: it is inside a constructor, the class
    /// has something above it with a constructor, and the arguments fit that constructor.
    /// Placement — that it is the <em>first</em> statement — is checked where the body is
    /// known, in <see cref="CheckSuperPlacement"/>.
    /// </summary>
    private EmType SuperCallType(Expr.Call c, Expr.Variable written, List<EmType> given)
    {
        _sawSuperCall = true;

        if (!_inConstructor)
        {
            Error(written.Name.Line,
                  "super(...) builds the base part of an object, so it belongs in a "
                  + "constructor.",
                  "To call a method the class above declares, name it:  "
                  + "super.method_name()");
            return EmType.Nothing;
        }

        if (_currentType?.Base is not { } above)
        {
            Error(written.Name.Line,
                  $"{_currentType?.Name ?? "This"} extends nothing, so there is no base "
                  + "constructor to call.");
            return EmType.Nothing;
        }

        if (!above.HasConstructor && above.Base is null)
        {
            Error(written.Name.Line,
                  $"{above.Name} has no constructor, so there is nothing to call.",
                  $"Its fields are given their values where they are declared, so "
                  + $"{_currentType!.Name} has only its own to fill.");
            return EmType.Nothing;
        }

        var wanted = new EmType.Func(above.ConstructorParams, EmType.Nothing,
                                     above.ConstructorRequired);
        CheckArguments(wanted, c, given, $"{above.Name}'s constructor", written.Name.Line);
        return EmType.Nothing;
    }

    private static EmType? Wanted(EmType callee, int position) => callee switch
    {
        EmType.Func fn when position < fn.Params.Count => fn.Params[position],

        // An overload set only helps when every version agrees about this position, which
        // is the common case for a block: one shape, differing in the arguments before it.
        EmType.Overloads set when set.Alternatives
            .Where(f => position < f.Params.Count)
            .Select(f => f.Params[position])
            .Distinct()
            .ToList() is [var only] => only,

        _ => null,
    };

    private EmType NonMemberCallType(Expr.Call c, List<EmType> given, Scope scope)
    {
        // Constructing a type: reject traits and anything with unimplemented members.
        if (c.Callee is Expr.Variable typeName
            && _classes.TryGetValue(typeName.Name.Lexeme, out var target))
        {
            if (target.Kind == TypeKind.Enum)
                Error(typeName.Name.Line,
                      $"{target.Name} is an enum, so it has only the values it declares.",
                      $"Use one of them:  {target.Name}."
                      + $"{target.StaticFields.Keys.FirstOrDefault(k => k != "values") ?? "FIRST"}");
            else if (target.Kind == TypeKind.Trait)
                Error(typeName.Name.Line,
                      $"{target.Name} is a trait, so it cannot be created directly.",
                      $"Traits are mixed into a class:  class Dog with {target.Name}");
            else if (target.Missing().FirstOrDefault() is { } missing)
                Error(typeName.Name.Line,
                      $"Cannot create {target.Name} — {missing} has no implementation.",
                      "Implement it here, or create a subclass that does.");
        }

        // Pair(a, b) is a call rather than a literal. A literal would need punctuation the
        // grammar does not have spare: (a, b) collides with grouping, and every other
        // bracket is spoken for. A call needs nothing new and reads the same.
        if (c.Callee is Expr.Variable { Name.Lexeme: "Pair" } && !_classes.ContainsKey("Pair"))
        {
            if (c.Args.Count != 2 || c.Trailing is not null)
            {
                Error(LineOf(c.Callee), $"Pair takes two values, got {c.Args.Count}.",
                      "One for each half:  Pair(name, score)");
                return EmType.Any;
            }

            return new EmType.PairOf(given[0], given[1]);
        }

        // super(...) builds the base part of this object. It is not an ordinary call —
        // there is no value named super to look up — so it is answered here before the
        // callee is resolved, and refused everywhere it does not belong (§3.2).
        if (c.Callee is Expr.Variable { Name.Lexeme: "super" } superCall)
            return SuperCallType(c, superCall, given);

        // A bare `print(x)` reaches here rather than the Kernel path, and it is the same
        // check: nothing else takes Any, so nothing else can miss a forgotten () (§3.1).
        if (c.Callee is Expr.Variable { Name.Lexeme: "print" })
            for (int i = 0; i < c.Args.Count && i < given.Count; i++)
                NotAFunction(given[i], c.Args[i]);

        var callee = TypeOf(c.Callee, scope);

        // A trailing block is typed here rather than with the other arguments, because the
        // shape it should have is written on the function receiving it — the same
        // contextual inference that lets `numbers.map { x => x * 2 }` know x is an Int, now
        // available to a function anyone can write.
        if (c.Trailing is not null)
            given.Add(TypeOf(c.Trailing, scope, Wanted(callee, given.Count)));

        if (callee is EmType.Unknown) return EmType.Any;

        if (callee is EmType.Overloads alternatives)
        {
            string overloaded = c.Callee is Expr.Variable which ? which.Name.Lexeme : "This";
            int supplied = given.Count;

            // At most one can match: §3.2 refused any pair a call could not tell apart, so
            // there is no "best match" rule here and none to explain to anyone.
            var chosen = alternatives.Alternatives.FirstOrDefault(f => Fits(f, supplied, given));
            if (chosen is not null)
            {
                Choose(c, chosen);
                return chosen.Return;
            }

            Error(LineOf(c.Callee),
                  $"No version of {overloaded} takes "
                  + (given.Count == 0
                        ? "no arguments."
                        : $"({string.Join(", ", given.Select(t => t.Show()))})."),
                  "It has " + string.Join(", and ", alternatives.Alternatives.Select(
                      f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".");
            return EmType.Any;
        }

        if (callee is not EmType.Func fn)
        {
            Error(LineOf(c.Callee), $"{callee.Show()} cannot be called.");
            return EmType.Any;
        }


        string name = c.Callee is Expr.Variable named ? named.Name.Lexeme : "This";
        Choose(c, fn);
        return CheckArguments(fn, c, given, name, LineOf(c.Callee));
    }

    /// <summary>
    /// A call to a built-in method. Separate from <see cref="CheckArguments"/> because a
    /// block is not an argument in the sense the parentheses mean — <c>5.times { }</c>
    /// passes none and one — so the two counts have to be kept apart.
    /// </summary>
    /// <summary>How many arguments a built-in wants, when some of them are optional.</summary>
    private static string Wanted(Signatures.Signature signature) =>
        signature.Least == signature.Takes.Length
            ? Count(signature.Takes.Length, "argument")
            : $"{signature.Least} or {signature.Takes.Length} arguments";

    private EmType CheckBuiltinCall(
        Signatures.Signature signature, Expr.Call c, List<EmType> given,
        EmType receiver, Token name)
    {
        string what = $"{receiver.Show()}.{name.Lexeme}";

        if (given.Count < signature.Least || given.Count > signature.Takes.Length)
            Error(name.Line,
                  $"{what} takes {Wanted(signature)}, but got {given.Count}.",
                  signature.Takes.Length == 0
                      ? null
                      : $"It wants {string.Join(", ", signature.Takes.Select(t => t.Show()))}.");
        else
            for (int i = 0; i < given.Count; i++)
                if (!signature.Takes[i].Accepts(given[i]))
                    Error(LineOf(c.Args[i]) is var at && at > 0 ? at : name.Line,
                          $"{what} expects {signature.Takes[i].Show()} "
                          + $"{Ordinal(i)}, but this is {given[i].Show()}.",
                          Widening(signature.Takes[i], given[i]));

        if (signature.WantsBlock && c.Trailing is null)
            Error(name.Line,
                  $"{what} needs a block.",
                  $"Write what to do each time:  {name.Lexeme} {{ i => ... }}");

        if (!signature.WantsBlock && c.Trailing is not null)
            Error(name.Line, $"{what} does not take a block.");

        return signature.Returns;
    }

    /// <summary>
    /// How many arguments a call may pass, and what each one must be.
    ///
    /// Shared by every call shape on purpose. Free functions were checked here and methods
    /// were not, because the two resolved through different code paths and only one of them
    /// had ever counted anything — so <c>dog.rename("a", "b", "c")</c> sailed past the
    /// checker while <c>rename("a", "b", "c")</c> did not. One routine means a method's
    /// diagnostic cannot drift from a function's, and cannot go missing.
    /// </summary>
    private EmType CheckArguments(
        EmType.Func fn, Expr.Call c, List<EmType> given, string what, int line,
        ClassInfo? owner = null, string? method = null)
    {
        int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);

        if (supplied < fn.LeastArgs || supplied > fn.Params.Count)
        {
            // With defaults there is a range rather than a number, and saying "takes 3"
            // when two would have done sends the reader to add an argument they do not need.
            string wanted = fn.LeastArgs == fn.Params.Count
                ? Count(fn.Params.Count, "argument")
                : $"between {fn.LeastArgs} and {Count(fn.Params.Count, "argument")}";

            Error(line, $"{what} takes {wanted}, but got {supplied}.");
            return fn.Return;
        }

        // Only positions the caller actually wrote. A defaulted parameter left off was
        // checked where the default was declared.
        for (int i = 0; i < given.Count && i < fn.Params.Count; i++)
        {
            if (fn.Params[i].Accepts(given[i])) continue;

            Error(i < c.Args.Count && LineOf(c.Args[i]) is var at && at > 0 ? at : line,
                  $"{what} expects {fn.Params[i].Show()} "
                  + $"{Ordinal(i)}, but this is {given[i].Show()}.",
                  Widening(fn.Params[i], given[i]) ?? BlockShape(fn.Params[i], given[i]),
                  topic: "argument-type");
        }

        return fn.Return;
    }

    /// <summary>"as its first argument" — a position a reader can find without counting
    /// commas from zero.</summary>
    private static string Ordinal(int index) => index switch
    {
        0 => "as its first argument",
        1 => "as its second argument",
        2 => "as its third argument",
        3 => "as its fourth argument",
        _ => $"as argument {index + 1}"
    };

    // ---- helpers --------------------------------------------------------

    /// <summary>"1 argument" not "1 argument(s)" — small, but "(s)" reads as unfinished.</summary>
    private static string Count(int n, string noun) =>
        n == 1 ? $"1 {noun}" : $"{n} {noun}s";

    /// <summary>
    /// "An" or "A" — small, but a diagnostic that says "A Int" reads as careless. Given
    /// capitalized because most uses start a sentence; the rest lower it themselves.
    /// </summary>
    private static string Article(string word) =>
        "AEIOU".Contains(char.ToUpperInvariant(word[0])) ? "An" : "A";

    // ---- lists  ---------------------------------------------------------

    private EmType ListLiteralType(Expr.ListLiteral a, Scope scope)
    {
        if (a.Items.Count == 0) return new EmType.Lst(EmType.Any);

        var types = a.Items.Select(i => TypeOf(i, scope)).ToList();
        var common = types[0];

        for (int i = 1; i < types.Count; i++)
        {
            var merged = CommonType(common, types[i]);
            if (merged is null)
            {
                Error(a.Bracket.Line,
                      $"This list holds {common.Show()} but item {i + 1} is {types[i].Show()}.",
                      "Every item in a list has to share a type.");
                return new EmType.Lst(EmType.Any);
            }
            common = merged;
        }

        return new EmType.Lst(common);
    }

    /// <summary>
    /// <c>["a": 1]</c> — the narrowest key type and the narrowest value type both items
    /// share, by the same rule a list literal uses.
    /// </summary>
    private EmType DictLiteralType(Expr.DictLiteral d, Scope scope)
    {
        if (d.Entries.Count == 0) return new EmType.Dict(EmType.Any, EmType.Any);

        EmType? keys = null;
        EmType? values = null;

        foreach (var entry in d.Entries)
        {
            var key = TypeOf(entry.Key, scope);
            var value = TypeOf(entry.Value, scope);

            if (keys is null) { keys = key; values = value; continue; }

            var mergedKey = CommonType(keys, key);
            if (mergedKey is null)
            {
                Error(d.Bracket.Line,
                      $"This dictionary is keyed by {keys.Show()} but a key is {key.Show()}.",
                      "Every key has to share a type, and every value has to share one.");
                return new EmType.Dict(EmType.Any, EmType.Any);
            }

            var mergedValue = CommonType(values!, value);
            if (mergedValue is null)
            {
                Error(d.Bracket.Line,
                      $"This dictionary holds {values!.Show()} but a value is {value.Show()}.",
                      "Every value has to share a type.");
                return new EmType.Dict(mergedKey, EmType.Any);
            }

            keys = mergedKey;
            values = mergedValue;
        }

        CheckKeyType(keys!, d.Bracket.Line);
        return new EmType.Dict(keys!, values!);
    }

    /// <summary>
    /// What may be a key. Restricted to the primitives, because looking one up needs
    /// hashing and equality that the runtime can perform — and a user type's idea of
    /// sameness lives in <c>equals?</c>, an Emerald method the host dictionary cannot see.
    /// Allowing it would compare by identity instead, so two equal-looking keys would miss
    /// each other: a wrong answer with no diagnostic, which is the worst kind.
    /// </summary>
    private void CheckKeyType(EmType key, int line, string role = "key")
    {
        if (key is EmType.Unknown) return;
        if (key.Equals(EmType.Int) || key.Equals(EmType.Float)
            || key.Equals(EmType.String) || key.Equals(EmType.Bool)) return;

        Error(line,
              role == "key"
                  ? $"A dictionary cannot be keyed by {key.Show()}."
                  : $"A set cannot hold {key.Show()}.",
              $"{(role == "key" ? "Keys" : "Members")} are Int, Float, String, or Bool. "
              + "Finding a value again needs hashing, and a type's own equals? is not "
              + "something the lookup can consult yet.");
    }

    /// <summary>
    /// The narrowest type that holds both — for <c>[rex, tweety]</c>, the class they share.
    /// Needed only once inheritance exists; before that, "the first item's type" sufficed,
    /// which is why this gap stayed invisible until classes landed.
    /// </summary>
    private static EmType? CommonType(EmType a, EmType b)
    {
        if (a is EmType.Unknown) return b;
        if (b is EmType.Unknown) return a;
        if (a.Accepts(b)) return a;
        if (b.Accepts(a)) return b;

        // `nothing` beside a value is not a clash — it is what makes the pair optional.
        // `["ada", nothing]` is a List<String?>, the type you would otherwise have had to
        // write out and fill with .add, one item at a time, because the literal refused.
        if (a.Equals(EmType.Nothing)) return EmType.Nullable(b);
        if (b.Equals(EmType.Nothing)) return EmType.Nullable(a);

        if (a is EmType.Obj x && b is EmType.Obj y)
            for (var candidate = x.Info; candidate is not null; candidate = candidate.Base)
                if (y.Info.IsSubclassOf(candidate)) return new EmType.Obj(candidate);

        return null;
    }

    private EmType IndexType(Expr.Index ix, Scope scope)
    {
        var target = TypeOf(ix.Target, scope);

        // A dictionary is looked up before the Int requirement, since its key is whatever
        // it was declared to be. It also gives back V? rather than V: a missing key is the
        // ordinary case for a lookup, where a missing list position is a bug.
        if (target is EmType.Dict dict)
        {
            var key = TypeOf(ix.Position, scope);
            if (!dict.Key.Accepts(key))
                Error(ix.Bracket.Line,
                      $"This dictionary is keyed by {dict.Key.Show()}, "
                      + $"but this is {key.Show()}.",
                      Widening(dict.Key, key));

            return EmType.Nullable(dict.Value);
        }

        Expect(TypeOf(ix.Position, scope), EmType.Int, ix.Position, "an index");

        if (target is EmType.Lst list) return list.Element;
        if (target is EmType.Unknown) return EmType.Any;

        // A user type reaches a[i] through Indexable, the same way + goes through Addable.
        if (target is EmType.Obj obj)
        {
            var at = obj.Info.FindMethod(Prelude.AtMethod);
            if (at is not null) return at.Return;

            Error(ix.Bracket.Line,
                  $"{target.Show()} cannot be indexed with [].",
                  $"Mix in {Prelude.IndexableTrait} and define {Prelude.AtMethod}:  "
                  + $"class {target.Show()} with {Prelude.IndexableTrait}");
            return EmType.Any;
        }

        Error(ix.Bracket.Line, $"Cannot index {target.Show()}.",
              target switch
              {
                  EmType.Prim { Name: "String" } =>
                      "Emerald strings are not integer-indexed. Use .chars() to get characters.",

                  // A set has no positions — membership is the question it answers.
                  EmType.SetOf => "A set has no order to index into. Ask whether it holds "
                                  + "something with .contains?(), or take .to_list() first.",

                  _ => null,
              });
        return EmType.Any;
    }

    /// <summary>
    /// The core twenty (§3.7). Return types are element-dependent, so these are computed
    /// rather than looked up — and the block's parameter is bound to the element type on
    /// the way in, which is what lets <c>{ x =&gt; ... }</c> know what x is.
    /// </summary>
    /// <summary>
    /// What a dictionary method gives back. Like the list methods, these depend on the key
    /// and value types, so they are computed rather than looked up in a table.
    /// </summary>
    /// <summary>
    /// The members every container shares, typed once for all four.
    ///
    /// <paramref name="yields"/> is what the block is handed: one element from a list, set
    /// or range, and a key beside a value from a dictionary — matching the two-parameter
    /// block its <c>each</c> has always taken. Everything that differs between containers
    /// is carried in that argument and in <paramref name="receiver"/>, so there is one
    /// place where <c>map</c> means something and one place to change it.
    /// </summary>
    private EmType IterableMemberType(
        EmType receiver, EmType[] yields, Token name, Expr.Call? call, Scope scope)
    {
        // A dictionary's element is the pair of what it yields. Before Pair existed there
        // was no such type, and the members handing an element back were refused on a
        // dictionary outright.
        bool inPairs = yields.Length > 1;
        EmType element = inPairs ? new EmType.PairOf(yields[0], yields[1]) : yields[0];
        EmType blockReturn = EmType.Any;
        EmType firstArg = EmType.Any;

        if (call is not null)
        {
            if (call.Args.Count > 0) firstArg = TypeOf(call.Args[0], scope);

            if (call.Trailing is { } block)
            {
                // reduce walks with a running total beside whatever the container yields;
                // everything else hands over just the yield. Given as a shape rather than
                // a single hint, because a dictionary's two are not the same type.
                List<EmType> takes = name.Lexeme switch
                {
                    "reduce" => [firstArg, .. yields],

                    // The index goes last, so naming it stays opt-in and a block that
                    // wants only the item is unchanged.
                    "each_with_index" => [.. yields, EmType.Int],

                    _ => [.. yields],
                };

                if (LambdaType(block, scope, shape: new EmType.Func(takes, EmType.Any),
                               supplies: takes.Count, given: name.Lexeme)
                    is EmType.Func typed) blockReturn = typed.Return;

                // A predicate has to answer yes or no. Without this a block giving back
                // anything at all was accepted and then read for truthiness, so
                // `filter { x => x.even? }` -- the method itself rather than its answer --
                // kept every element instead of the even ones, `all?` said true, `find`
                // returned the first item and `reject` gave back nothing. Four plausible
                // wrong answers from one missing pair of parentheses, and a plausible
                // wrong answer is worse than an error.
                //
                // Made possible by §3.1: a member read now names a method rather than
                // calling it, which is what makes callbacks work and what puts a callable
                // one keystroke away from every predicate.
                if (name.Lexeme is "filter" or "reject" or "find" or "any?" or "all?"
                    && blockReturn is not EmType.Unknown
                    && !blockReturn.Equals(EmType.Bool)
                    && !blockReturn.Equals(EmType.Nothing))
                {
                    // The body written out, so the fix names what they typed rather than
                    // an invented example they then have to translate.
                    string? shown = block.Body is [Stmt.ExprStmt { Expression: Expr.Get } only]
                        ? Source.Of(only.Expression)
                        : null;

                    Error(name.Line,
                          $"{name.Lexeme} needs a yes or no from its block, and this gives "
                          + $"back {blockReturn.Show()}.",
                          blockReturn is EmType.Func
                              ? "That is the method itself, not its answer. Add parentheses "
                                + $"to call it:  {shown ?? "x.even?"}()"
                              : $"A predicate answers yes or no, so the block has to end in "
                                + "something that is true or false.");
                }

                // each is the one that does not look at the answer. For the rest the
                // block's value is the whole point, so a block with none is the mistake.
                if (name.Lexeme is not ("each" or "each_with_index")
                    && blockReturn.Equals(EmType.Nothing))
                    Error(name.Line,
                          $"This block gives nothing back, but {name.Lexeme} needs an "
                          + "answer from it.",
                          "A block of one expression answers with it. A longer one says "
                          + "which value it gives:  return ...");
            }
        }

        // min, max and sum order or add their elements, and a pair does neither -- there
        // is no arrangement of two values of different types that says which pair is
        // larger. min_by and max_by still work, because the block supplies the ordering.
        if (inPairs && name.Lexeme is "min" or "max" or "sum")
        {
            Error(name.Line,
                  $"{name.Lexeme} is not available on {receiver.Show()}.",
                  $"A pair has no order of its own. Use one half:  "
                  + $"scores.values().{name.Lexeme}()"
                  + (name.Lexeme == "sum" ? "" : ", or min_by / max_by with a block"));
            return EmType.Any;
        }

        return name.Lexeme switch
        {
            "map" => new EmType.Lst(blockReturn),

            // Narrowing a container does not change what it is, so a filtered set is a
            // set and a filtered dictionary is a dictionary. A range is the exception and
            // gives a list: 1..10 without its odds is not a range, and no representation
            // Emerald has could hold one.
            "filter" or "reject" =>
                receiver.Equals(EmType.Range) ? new EmType.Lst(element) : receiver,

            "find" or "min" or "max" or "min_by" or "max_by" => EmType.Nullable(element),
            "to_list" => new EmType.Lst(element),

            // A run of elements is still the container it came from, on the same rule
            // filter follows -- and a range is still the same exception.
            "take" or "drop" =>
                receiver.Equals(EmType.Range) ? new EmType.Lst(element) : receiver,

            "group_by" => new EmType.Dict(blockReturn, new EmType.Lst(element)),
            "count" => EmType.Int,
            "sum" => element.Equals(EmType.Float) ? EmType.Float : EmType.Int,
            "any?" or "all?" or "empty?" => EmType.Bool,
            "reduce" => firstArg,
            _ => EmType.Nothing,
        };
    }

    private EmType SetMemberType(EmType.SetOf set, Token name, Expr.Call? call, Scope scope)
    {
        if (call is not null)
        {
            List<EmType> given = [.. call.Args.Select(arg => TypeOf(arg, scope))];

            // These take a member; those take another set of the same kind. Checked here
            // rather than in the shared call machinery, because a built-in container's
            // methods have no signature table to check against.
            var wanted = name.Lexeme switch
            {
                "add" or "remove" or "contains?" => set.Element,
                "union" or "intersect" or "difference" or "subset_of?"
                    or "superset_of?" or "disjoint?" => set,
                _ => null,
            };

            if (wanted is not null && given.Count > 0 && !wanted.Accepts(given[0]))
                Error(name.Line,
                      $"{name.Lexeme} on {set.Show()} takes {wanted.Show()}, "
                      + $"but this is {given[0].Show()}.",
                      Widening(wanted, given[0]));

            if (Builtins.Shared.Contains(name.Lexeme))
                return IterableMemberType(set, [set.Element], name, call, scope);

            if (call.Trailing is not null) TypeOf(call.Trailing, scope);
        }

        if (Builtins.Shared.Contains(name.Lexeme))
            return IterableMemberType(set, [set.Element], name, call, scope);

        return name.Lexeme switch
        {
            "contains?" or "subset_of?" or "superset_of?" or "disjoint?" => EmType.Bool,
            "union" or "intersect" or "difference" => set,
            "add" or "remove" or "clear" => EmType.Nothing,

            _ => NoSuchMember(name, set.Show(), Signatures.SetMethods),
        };
    }

    private EmType DictMemberType(EmType.Dict dict, Token name, Expr.Call? call, Scope scope)
    {
        if (call is not null)
        {
            List<EmType> given = [.. call.Args.Select(arg => TypeOf(arg, scope))];

            var wanted = name.Lexeme switch
            {
                "has_key?" or "get" or "remove" or "set" => dict.Key,
                "has_value?" => dict.Value,
                _ => null,
            };

            if (wanted is not null && given.Count > 0 && !wanted.Accepts(given[0]))
                Error(name.Line,
                      $"{name.Lexeme} on {dict.Show()} takes {wanted.Show()}, "
                      + $"but this is {given[0].Show()}.",
                      Widening(wanted, given[0]));

            if (name.Lexeme == "set" && given.Count > 1 && !dict.Value.Accepts(given[1]))
                Error(name.Line,
                      $"This dictionary holds {dict.Value.Show()}, "
                      + $"but this gives it {given[1].Show()}.",
                      Widening(dict.Value, given[1]));

            // A dictionary hands its block a key beside a value, which is the shape its
            // each has always had and now the shape map, filter and the rest inherit.
            if (Builtins.Shared.Contains(name.Lexeme))
                return IterableMemberType(dict, [dict.Key, dict.Value], name, call, scope);

            if (call.Trailing is not null) TypeOf(call.Trailing, scope);
        }

        if (Builtins.Shared.Contains(name.Lexeme))
            return IterableMemberType(dict, [dict.Key, dict.Value], name, call, scope);

        return name.Lexeme switch
        {
            "has_key?" => EmType.Bool,
            "has_value?" => EmType.Bool,
            "keys" => new EmType.Lst(dict.Key),
            "values" => new EmType.Lst(dict.Value),

            // Same answer as d[key], and the same reason: a lookup that misses is normal.
            "get" => EmType.Nullable(dict.Value),

            "set" or "remove" or "clear" or "each" => EmType.Nothing,

            _ => Unknown(name, dict),
        };
    }

    private EmType NoSuchMember(Token name, string on, IEnumerable<string> candidates)
    {
        // .or and .must belong to T?, so meeting one on a plain T almost always means the
        // value was checked already and the fallback is left over from before the check.
        // Without this the reader is told a method is missing, when what changed is that
        // the check above made it unnecessary.
        string? hint = name.Lexeme is "or" or "must"
            ? $"{name.Lexeme} belongs to an optional. This is {on}, which always holds a "
              + "value, so the fallback can go."
            : Suggest(name.Lexeme, candidates);

        Error(name.Line, $"No method named {name.Lexeme} on {on}.", hint);
        return EmType.Any;
    }

    private EmType Unknown(Token name, EmType.Dict dict)
    {
        // contains? is what a list calls this, and on a dictionary the question has two
        // answers — so the suggestion has to name both rather than pick one.
        string? hint = name.Lexeme is "contains?" or "includes?" or "has?"
            ? "A dictionary can be asked about either half:  has_key? or has_value?"
            : Suggest(name.Lexeme, Signatures.DictMethods);

        Error(name.Line, $"No method named {name.Lexeme} on {dict.Show()}.", hint);
        return EmType.Any;
    }

    private EmType ListCallType(EmType.Lst list, Expr.Call c, Token name, Scope scope)
    {
        if (Builtins.Shared.Contains(name.Lexeme))
            return IterableMemberType(list, [list.Element], name, c, scope);

        foreach (var arg in c.Args) TypeOf(arg, scope);

        EmType blockReturn = EmType.Any;
        if (c.Trailing is not null)
        {
            var hint = Signatures.TakesElementBlock.Contains(name.Lexeme) ? list.Element : null;

            // reduce walks with a running total beside the item; everything else hands the
            // block one element at a time.
            int supplies = name.Lexeme == "reduce" ? 2 : 1;

            if (LambdaType(c.Trailing, scope, hint, supplies: supplies, given: name.Lexeme)
                is EmType.Func f) blockReturn = f.Return;

            // each is the one that does not look at the answer. For the rest the block's
            // value is the whole point, so a block with none to give is the mistake.
            if (name.Lexeme != "each" && blockReturn.Equals(EmType.Nothing))
                Error(name.Line,
                      $"This block gives nothing back, but {name.Lexeme} needs an answer "
                      + "from it.",
                      "A block of one expression answers with it. A longer one says which "
                      + "value it gives:  return ...");
        }

        return ListMemberType(list, name, blockReturn,
                               c.Args.Count > 0 ? TypeOf(c.Args[0], scope) : EmType.Any);
    }

    /// <summary>
    /// The shape of <c>arr.count()</c> and every other list method. Reached from the
    /// call path only: a paren-less <c>arr.count</c> names nothing, since the built-ins
    /// have no properties for it to name (§3.1).
    /// </summary>
    private EmType ListMemberType(
        EmType.Lst list, Token name, EmType blockReturn, EmType firstArg)
    {
        EmType element = list.Element;

        if (!Signatures.ListMethods.Contains(name.Lexeme))
        {
            Error(name.Line, $"No method named {name.Lexeme} on {list.Show()}.",
                  PredicateSwallowed(name, Signatures.ListMethods)
                      ?? Suggest(name.Lexeme, Signatures.ListMethods));
            return EmType.Any;
        }

        return name.Lexeme switch
        {
            "sort" or "sort_by" or "reverse" => list,

            // These can miss, so they give back a maybe and the checker insists you deal
            // with it. The clearest place the nullability design earns itself.
            "first" or "last" => EmType.Nullable(element),

            "index_of" => EmType.Int,
            "contains?" => EmType.Bool,
            "join" => EmType.String,
            "insert_at" => EmType.Nothing,

            // Stops at the shorter side, so the element type is a pair of the two, never
            // a maybe -- there is no position where only one half exists.
            "zip" => new EmType.Lst(new EmType.PairOf(
                element, firstArg is EmType.Lst other ? other.Element : EmType.Any)),

            // A set has no literal of its own — the braces Python uses are a block and a
            // trailing lambda here, and the bracket is already a list's. So a list is how
            // one is written, and .to_set is the visible step between them.
            "to_set" => Setify(list, name),
            _ => EmType.Nothing,
        };
    }

    /// <summary>
    /// <c>list.to_set</c>. The members must be hashable for the same reason a
    /// dictionary's keys must be, so the check is the same one.
    /// </summary>
    private EmType Setify(EmType.Lst list, Token name)
    {
        CheckKeyType(list.Element, name.Line, "member");
        return new EmType.SetOf(list.Element);
    }

    private static bool IsNumeric(EmType t) =>
        t is EmType.Unknown || t.Equals(EmType.Int) || t.Equals(EmType.Float);

    private EmType Resolve(TypeRef? annotation)
    {
        if (annotation is null) return EmType.Any;

        // func(Int): String. Every parameter is required — a declared shape says what the
        // caller must supply, and a default belongs to the function being written, not to
        // the description of one being asked for.
        if (annotation.Function is { } shape)
        {
            List<EmType> takes = [.. shape.Params.Select(Resolve)];
            var callable = new EmType.Func(
                takes, shape.Returns is null ? EmType.Nothing : Resolve(shape.Returns),
                Required: takes.Count);

            return annotation.Nullable ? EmType.Nullable(callable) : callable;
        }

        // List is the one generic a program may write down (§5.3). It must say what it
        // holds: the checker has always been able to represent List<String>, and only the
        // annotation grammar could not spell it — which meant a named function could not
        // take a list at all, since parameters must be annotated.
        var given = annotation.Arguments;

        if (annotation.Name.Lexeme == "List")
        {
            if (given is null || given.Count != 1)
            {
                Error(annotation.Name.Line,
                      given is null
                          ? "List needs to say what it holds."
                          : $"List takes one type, not {given.Count}.",
                      "Write the element type in angle brackets:  List<String>",
                      topic: "list-type");
                return EmType.Any;
            }

            var listType = new EmType.Lst(Resolve(given[0]));
            return annotation.Nullable ? EmType.Nullable(listType) : listType;
        }

        if (annotation.Name.Lexeme == "Dictionary")
        {
            if (given is null || given.Count != 2)
            {
                Error(annotation.Name.Line,
                      given is null
                          ? "Dictionary needs to say what it maps to what."
                          : $"Dictionary takes two types, not {given.Count}.",
                      "The key type then the value type:  Dictionary<String, Int>",
                      topic: "dictionary-type");
                return EmType.Any;
            }

            var key = Resolve(given[0]);
            CheckKeyType(key, annotation.Name.Line);

            var dictType = new EmType.Dict(key, Resolve(given[1]));
            return annotation.Nullable ? EmType.Nullable(dictType) : dictType;
        }

        if (annotation.Name.Lexeme == "Set")
        {
            if (given is null || given.Count != 1)
            {
                Error(annotation.Name.Line,
                      given is null
                          ? "Set needs to say what it holds."
                          : $"Set takes one type, not {given.Count}.",
                      "Write the member type in angle brackets:  Set<String>",
                      topic: "set-type");
                return EmType.Any;
            }

            var member = Resolve(given[0]);
            CheckKeyType(member, annotation.Name.Line, "member");

            var setType = new EmType.SetOf(member);
            return annotation.Nullable ? EmType.Nullable(setType) : setType;
        }

        // Pair<A, B>. Both halves are free -- unlike a set member or a dictionary key,
        // nothing hashes a pair, so there is no restriction to impose.
        if (annotation.Name.Lexeme == "Pair")
        {
            if (given is null || given.Count != 2)
            {
                Error(annotation.Name.Line,
                      given is null
                          ? "Pair needs to say what it holds."
                          : $"Pair takes two types, not {given.Count}.",
                      "Both halves in angle brackets:  Pair<String, Int>",
                      topic: "pair-type");
                return EmType.Any;
            }

            var pairType = new EmType.PairOf(Resolve(given[0]), Resolve(given[1]));
            return annotation.Nullable ? EmType.Nullable(pairType) : pairType;
        }

        if (given is not null)
            Error(annotation.Name.Line,
                  $"{annotation.Name.Lexeme} does not take type arguments.",
                  "List, Dictionary and Set are the only generic types in Emerald, and all "
                  + "three are built in — a program cannot declare its own.");

        EmType baseType = annotation.Name.Lexeme switch
        {
            "Int" => EmType.Int,
            "Float" => EmType.Float,
            "String" => EmType.String,
            "Bool" => EmType.Bool,
            "Range" => EmType.Range,
            "Nothing" => EmType.Nothing,
            var other => _classes.TryGetValue(other, out var info)
                ? new EmType.Obj(info)
                : Unknown(annotation.Name.Line, other)
        };

        return annotation.Nullable ? EmType.Nullable(baseType) : baseType;
    }

    private EmType Unknown(int line, string name)
    {
        Error(line, $"No type named {name}.",
              "Emerald knows Int, Float, String, Bool, Range, List<...>, and Nothing.");
        return EmType.Any;
    }

    /// <summary>
    /// <paramref name="fallback"/> is used when the expression carries no token to point
    /// at — a bare literal has none, and reporting line 0 points at nothing at all.
    /// </summary>
    private void Expect(EmType actual, EmType wanted, Expr where, string context, int fallback = 0)
    {
        if (actual is EmType.Unknown || wanted.Accepts(actual)) return;
        Error(LineOf(where) is var line && line > 0 ? line : fallback,
              $"{context} needs {wanted.Show()}, but this is {actual.Show()}.",

              // A method read sitting one keystroke from its call is the likeliest way to
              // arrive here holding a function where a value was wanted, and §3.1 made
              // that read legal on purpose so callbacks could exist. Naming the call is
              // more use than naming the type it does not have.
              actual is EmType.Func && where is Expr.Get
                  ? "That is the method itself, not its answer. Add parentheses to call "
                    + $"it:  {Source.Of(where)}()"
                  : actual.IsMaybe ? "Check it against nothing first." : null);
    }

    private static string? Widening(EmType declared, EmType actual) =>
        declared.Stripped.Accepts(actual.Stripped) && actual.IsMaybe && !declared.IsMaybe
            ? $"Declare it as {declared.Show()}? if it can be nothing."
            : Container(declared.Stripped, actual.Stripped);

    /// <summary>
    /// Why a container of one thing is not a container of another. The refusal is the
    /// right one and the reason is invisible, which is exactly where §2.6 says the
    /// diagnostic has to do the teaching -- the elements <em>are</em> compatible, and a
    /// reader who knows that will read the error as the compiler being wrong.
    /// </summary>
    private static string? Container(EmType declared, EmType actual) =>
        (declared, actual) switch
        {
            (EmType.Lst want, EmType.Lst got) when want.Element.Accepts(got.Element)
                => Why(want.Element, got.Element, "list"),

            (EmType.SetOf want, EmType.SetOf got) when want.Element.Accepts(got.Element)
                => Why(want.Element, got.Element, "set"),

            (EmType.Dict want, EmType.Dict got)
                when want.Key.Accepts(got.Key) && want.Value.Accepts(got.Value)
                => Why(want.Value, got.Value, "dictionary"),

            _ => null,
        };

    /// <summary>The same mismatch, where the value was written out on the spot.</summary>
    private static string? Literally(EmType declared, EmType actual) =>
        (declared, actual) switch
        {
            (EmType.Lst want, EmType.Lst got) when want.Element.Accepts(got.Element)
                => $"The items are {got.Element.Show()}. Write them as "
                   + $"{want.Element.Show()}, like {Example(want.Element)}, or declare this "
                   + $"List<{got.Element.Show()}>.",

            (EmType.Dict want, EmType.Dict got)
                when want.Key.Accepts(got.Key) && want.Value.Accepts(got.Value)
                => $"The values are {got.Value.Show()}. Write them as "
                   + $"{want.Value.Show()}, like {Example(want.Value)}, or declare this "
                   + $"Dictionary<{got.Key.Show()}, {got.Value.Show()}>.",

            _ => null,
        };

    private static string Why(EmType want, EmType got, string kind) =>
        $"A {kind} of {got.Show()} is not a {kind} of {want.Show()}, even though "
        + $"{got.Show()} fits where {want.Show()} is wanted. Both names would be the same "
        + $"{kind}, so writing {Article(want.Show()).ToLowerInvariant()} {want.Show()} "
        + $"through one would break what the other "
        + $"says it holds.\n"
        + $"Build a new one holding {want.Show()}, or declare this {kind} of "
        + $"{got.Show()} too.";

    /// <summary>"did you mean" — high confidence only, per §3.6.</summary>
    private static string? Suggest(string typed, IEnumerable<string> candidates)
    {
        // A name this language calls something else — checked first, because edit
        // distance cannot connect `to_integer` to `to_int` or `quit` to `exit`.
        var pool = candidates.ToList();
        if (Signatures.KnownByAnotherName.TryGetValue(typed, out var actual)
            && pool.Contains(actual))
            return $"Emerald calls that {actual}.";

        // Distance 0 means they typed it correctly and the real fault is elsewhere —
        // suggesting the word back would be worse than saying nothing.
        var best = pool
            .Select(c => (name: c, distance: Distance(typed, c)))
            .Where(x => x.distance is >= 1 and <= 2)
            .OrderBy(x => x.distance)
            .FirstOrDefault();

        return best.name is null ? null : $"Did you mean {best.name}?";
    }

    private static int Distance(string a, string b)
    {
        var d = new int[a.Length + 1, b.Length + 1];
        for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
        for (int j = 0; j <= b.Length; j++) d[0, j] = j;

        for (int i = 1; i <= a.Length; i++)
            for (int j = 1; j <= b.Length; j++)
                d[i, j] = Math.Min(
                    Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1),
                    d[i - 1, j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));

        return d[a.Length, b.Length];
    }

    private static int LineOf(Expr expr) => expr switch
    {
        Expr.Variable v => v.Name.Line,
        Expr.Binary b => b.Op.Line,
        Expr.Logical l => l.Op.Line,
        Expr.Unary u => u.Op.Line,
        Expr.Get g => g.Name.Line,
        Expr.Call c => LineOf(c.Callee),
        Expr.Grouping g => LineOf(g.Inner),
        Expr.Literal l => l.Line,
        Expr.Index x => x.Bracket.Line,
        Expr.ListLiteral l => l.Bracket.Line,
        Expr.DictLiteral d => d.Bracket.Line,
        Expr.RangeExpr r => LineOf(r.Start),

        // An if expression's own line is its condition's, falling through to the branches
        // when the condition carries nothing — every part of it can be a bare literal.
        Expr.IfExpr i => First(LineOf(i.Condition), LineOf(i.Then), LineOf(i.Else)),
        Expr.Interpolation p => p.Parts.Select(LineOf).FirstOrDefault(n => n > 0),
        _ => 0
    };

    private static int First(params int[] lines) => lines.FirstOrDefault(n => n > 0);

    /// <summary>Where a statement begins, for the indentation check. Zero means the shape
    /// carries no usable token, and the statement is simply skipped.</summary>
    private static int LineOf(Stmt stmt) => stmt switch
    {
        Stmt.VarDecl v => v.Name.Line,
        Stmt.Assign a => a.Op.Line,
        Stmt.ExprStmt e => LineOf(e.Expression),
        Stmt.If i => LineOf(i.Condition),
        Stmt.While w => LineOf(w.Condition),
        Stmt.For f => f.Variable.Line,
        Stmt.FuncDecl fn => fn.Name.Line,
        Stmt.ClassDecl c => c.Name.Line,
        Stmt.ConstructorDecl c => c.Keyword.Line,
        Stmt.Return r => r.Keyword.Line,
        Stmt.Throw t => t.Keyword.Line,
        Stmt.Assert a => a.Keyword.Line,
        Stmt.TryCatch t => t.Keyword.Line,
        Stmt.Break b => b.Keyword.Line,
        Stmt.Continue c => c.Keyword.Line,
        _ => 0
    };

    // ---- misleading indentation (§3.5) ----------------------------------

    /// <summary>
    /// Statements in one block share one indentation. A statement indented more deeply
    /// than the statement above it, without being inside anything, reads as though it were
    /// nested — the shape of Apple's 2014 "goto fail", where a duplicated line indented as
    /// though guarded silently broke SSL certificate validation.
    ///
    /// Emerald's mandatory braces already make that exact bug unrepresentable. What
    /// remains is its cousin: a line sitting outside a block it appears to be inside,
    /// after the block has closed. A warning rather than a lint because §3.5 is explicit
    /// that a configurable lint is a rule somebody switches off.
    ///
    /// Only the first drift in a run is reported. A whole block indented by one extra
    /// space is one mistake, and forty warnings about it is the cascade §3.6 forbids.
    /// </summary>
    private void CheckIndentation(List<Stmt> statements, string file)
    {
        var lines = sourceOf?.Invoke(file);
        if (lines is null || lines.Length == 0) return;

        int baseline = -1;

        foreach (var stmt in statements)
        {
            int line = LineOf(stmt);
            if (line <= 0 || line > lines.Length) continue;

            string text = lines[line - 1];
            if (text.Trim().Length == 0) continue;

            int indent = text.Length - text.TrimStart().Length;

            if (baseline < 0) { baseline = indent; continue; }
            if (indent <= baseline) { baseline = indent; continue; }

            string previous = _file;
            _file = file;
            Warn(line,
                 "This line is indented further than the one above it, "
                 + "but it is not inside anything.",
                 "Everything in one block lines up. An indented line that is not nested "
                 + "reads as though it were guarded by the block above, which is how "
                 + "Apple's 2014 SSL bug went unnoticed.");
            _file = previous;

            baseline = indent;
        }
    }

    // ---- attributes (§3.8) ----------------------------------------------

    /// <summary>
    /// The whole vocabulary. Fixed and compiler-known: a program cannot invent one, which
    /// is what makes an unknown name an error a beginner can act on rather than a silently
    /// ignored line (§3.8).
    ///
    /// Three of the four generate no code and have no effect yet — they describe things
    /// for a backend that does not exist. They are checked now anyway, because an
    /// attribute that is accepted and ignored teaches that it works.
    /// </summary>
    private static readonly Dictionary<string, (string On, bool Takes, string Does)> KnownAttributes =
        new()
        {
            ["export"] = ("variable", false, "makes a field visible to the editor in a Unity-style host"),
            ["test"] = ("function", false, "marks a function to be run by the test runner"),
            ["mirrors"] = ("type", false, "says this type follows a foreign API's shape"),
            ["name"] = ("function", true, "overrides the name this is emitted under"),
        };

    /// <summary>
    /// Whether the type being checked carries <c>@mirrors</c>. Its members take a foreign
    /// API's names, which are not the programmer's to choose, so §3.4's casing rule has
    /// nothing to say about them.
    /// </summary>
    private bool _mirroring;

    private void CheckAttributes(List<Attr>? attributes, string target)
    {
        if (attributes is null) return;

        foreach (var attribute in attributes)
        {
            string name = attribute.Name.Lexeme;

            if (!KnownAttributes.TryGetValue(name, out var known))
            {
                Error(attribute.Name.Line,
                      $"There is no attribute named @{name}.",
                      Suggest(name, KnownAttributes.Keys.Select(k => "@" + k))
                      ?? "Emerald knows @export, @test, @mirrors, and @name. "
                         + "The set is fixed — a program cannot add to it.");
                continue;
            }

            if (known.On != target)
                Error(attribute.Name.Line,
                      $"@{name} belongs on a {known.On}, not on a {target}.",
                      $"It {known.Does}.");

            if (known.Takes && attribute.Argument is null)
                Error(attribute.Name.Line,
                      $"@{name} needs an argument.",
                      $"""It {known.Does}:  @{name}("Any")""");

            if (!known.Takes && attribute.Argument is not null)
                Error(attribute.Name.Line,
                      $"@{name} takes no argument.",
                      $"It {known.Does}, and needs nothing else to say so.");

            // @name's argument becomes an identifier in emitted metadata, so it has to be
            // known at compile time — a computed one could not be written into the assembly.
            if (known.Takes && attribute.Argument is not null
                && attribute.Argument is not Expr.Literal { Value: string })
                Error(attribute.Name.Line,
                      $"@{name} needs a plain text name.",
                      $"""Write it as a string:  @{name}("Any")""");
        }
    }

    private static bool Carries(List<Attr>? attributes, string name) =>
        attributes?.Any(a => a.Name.Lexeme == name) ?? false;

    // ---- naming (§3.4) --------------------------------------------------

    /// <summary>
    /// Two casings, one statable rule: types are capitalized, nothing else is. Warnings
    /// rather than errors, because renaming is a semantic change and a compiler that
    /// refuses to run over a style disagreement is a compiler people route around.
    ///
    /// The §3.4 exemption for members overriding an external type is not implemented and
    /// costs nothing yet: there is no interop, so no external type exists to override.
    /// <c>@mirrors</c> needs attributes, which do not parse.
    /// </summary>
    private void CheckCasing(Token name, string kind, bool isConst = false)
    {
        // A mirrored type takes a foreign API's names, which the programmer did not choose
        // and cannot change. Enforcing a convention nobody can comply with is noise.
        if (_mirroring) return;

        string text = name.Lexeme;

        // A predicate's trailing ? is part of its name, not a casing violation.
        string bare = text.TrimEnd('?');
        if (bare.Length == 0) return;

        if (kind == "type")
        {
            if (!char.IsUpper(bare[0]) || bare.Contains('_'))
                Warn(name.Line,
                     $"Type names are written in PascalCase, so {text} reads as something else.",
                     $"Rename it to {ToPascal(bare)}. Types are capitalized; nothing else is.",
                     topic: "casing");
            return;
        }

        if (isConst)
        {
            if (bare.Any(char.IsLower))
                Warn(name.Line,
                     $"Constants are written in SCREAMING_SNAKE_CASE, so {text} reads as a variable.",
                     $"Rename it to {ToScreaming(bare)}.");
            return;
        }

        if (bare.Any(char.IsUpper))
            Warn(name.Line,
                 $"{Article(kind)} {kind} is written in snake_case, so {text} reads as a type.",
                 $"Rename it to {ToSnake(bare)}. Capitalized names mean types in Emerald.",
                 topic: "casing");
    }

    /// <summary>
    /// A method returning Bool must end in <c>?</c>, and one ending in <c>?</c> must
    /// return Bool (§3.4). Ruby leaves this a convention, so the hint cannot be trusted;
    /// enforcing both directions makes <c>list.empty?</c> state its return type at the
    /// call site.
    /// </summary>
    /// <summary>
    /// <c>or</c> and <c>must</c> are what a <c>T?</c> is asked, and every value answers
    /// them the same way — a present one gives itself back (§3.2). A class that declared
    /// either name would make <c>city.or(...)</c> mean the fallback or the method
    /// depending on the variable's declared type rather than on what is written, so the
    /// names are reserved on instance members and the question never arises.
    /// </summary>
    private void CheckReservedMember(Token name, string kind)
    {
        if (name.Lexeme is not ("or" or "must")) return;

        string owner = _currentType?.Name ?? "This type";

        Error(name.Line,
              $"{kind} cannot be named {name.Lexeme} — that name belongs to optionals.",
              $"Every value answers .{name.Lexeme}: on {owner}? it stands in for the "
              + $"missing case, and on {owner} it gives the {owner} back. A member of that "
              + "name could never be reached.");
    }

    /// <summary>
    /// <c>to_string</c> is the one method the language calls on a program's behalf, so
    /// its shape is not the author's to choose: printing a value has nowhere to put an
    /// argument and nothing to do with an answer that is not text.
    ///
    /// An error rather than a warning, which <see cref="CheckPredicateName"/> is. The ?
    /// rule is about a name reading honestly and a program that ignores it still runs;
    /// this one is a contract the interpreter relies on, and breaking it would mean
    /// printing a value either failing or quietly falling back to the plain form.
    /// </summary>
    private void CheckToStringShape(Stmt.FuncDecl fn)
    {
        if (fn.Name.Lexeme != Builtins.ToStringMethod) return;

        if (fn.Params.Count > 0)
            Error(fn.Params[0].Name.Line,
                  $"{Builtins.ToStringMethod} cannot take arguments.",
                  "It is called for you wherever a value is printed or put in a string, "
                  + $"and there is nothing to hand it there:  func {Builtins.ToStringMethod}(): String");

        // The annotation is required here, where the ? rule lets one be left off. That
        // rule is about a name reading honestly; this is a contract, and an unannotated
        // to_string handing back an Int printed <C> with nothing said -- a value silently
        // ignoring the method written to describe it. C# cannot express the method
        // without the type either.
        if (fn.ReturnType is null)
            Error(fn.Name.Line,
                  $"{Builtins.ToStringMethod} has to say that it gives back String.",
                  $"It is the one method the language calls for you, so it says so out "
                  + $"loud:  func {Builtins.ToStringMethod}(): String");

        else if (!Resolve(fn.ReturnType).Equals(EmType.String))
            Error(fn.Name.Line,
                  $"{Builtins.ToStringMethod} gives back "
                  + $"{Resolve(fn.ReturnType).Show()}, not String.",
                  "It says how a value reads as text, so text is the only thing it can "
                  + $"give back:  func {Builtins.ToStringMethod}(): String");
    }

    /// <summary>
    /// A function that hands back a value has to say what kind. Without this the checker
    /// resolved a missing annotation to <see cref="EmType.Unknown"/>, which is compatible
    /// with everything, and <c>var word: String = answer()</c> bound an Int to a String
    /// with nothing said &mdash; <strong>not a conversion, and not a String holding
    /// digits: the variable held a genuine Int while the checker believed otherwise.</strong>
    /// The value then travelled, and the failure surfaced inside whatever correct,
    /// fully annotated function it reached, which is the diagnostic §3.6 exists to stop.
    ///
    /// Required rather than inferred. C#, Java and Swift all require it on a function
    /// with a block body, mutual recursion has no answer inference can reach without
    /// machinery nothing here needs, and a reader should learn what a function gives back
    /// from its first line rather than from its last. §3.7's rule for <c>to_string</c> is
    /// the same rule for the same reason.
    /// </summary>
    private void CheckReturnIsDeclared(Stmt.FuncDecl fn)
    {
        // An abstract declaration is a contract, and an unannotated one asks for nothing
        // in particular on purpose: the prelude writes abstract func add(other), and a
        // type's own add takes and returns itself.
        if (fn.Body is null || fn.ReturnType is not null) return;
        if (!ReturnsAValue(fn.Body)) return;

        // to_string is held to the same requirement by CheckToStringShape, which says why
        // in terms of what to_string is for. Two diagnostics about one line is one too
        // many, and the general one would offer the wrong type as its example.
        if (fn.Name.Lexeme == Builtins.ToStringMethod && !fn.IsStatic) return;

        // Named where it can be known for certain. A worked example carrying the wrong
        // type would teach the reader to write that one, so a guess is worse than none.
        string shown = FirstReturnedLiteral(fn.Body) is { } known ? known.Show() : "Int";

        Error(fn.Name.Line,
              $"{fn.Name.Lexeme} gives back a value, so it has to say what kind.",
              "Write the type after the parentheses:  "
              + $"func {fn.Name.Lexeme}(...): {shown}\n"
              + "Without it, a caller assigning the answer to a declared type has nothing "
              + "to check against, and a wrong one is found somewhere else entirely.");
    }

    /// <summary>
    /// The type of the first literal a body returns, where there is one. Enough to make
    /// the example in the diagnostic above name the right type in the case a beginner
    /// actually writes, without a scope to type an arbitrary expression against.
    /// </summary>
    private static EmType? FirstReturnedLiteral(List<Stmt> body)
    {
        foreach (var stmt in body)
            switch (stmt)
            {
                case Stmt.Return { Value: Expr.Literal l }: return LiteralType(l.Value);
                case Stmt.If i:
                    if (FirstReturnedLiteral(i.Then) is { } fromThen) return fromThen;
                    if (i.Else is not null && FirstReturnedLiteral(i.Else) is { } fromElse)
                        return fromElse;
                    break;
            }

        return null;
    }

    private void CheckPredicateName(Stmt.FuncDecl fn)
    {
        // An unannotated return type says nothing either way; guessing from the body
        // would make the rule fire on functions that never claimed to be predicates.
        if (fn.ReturnType is null) return;

        bool asksQuestion = fn.Name.Lexeme.EndsWith('?');
        bool answersOne = Resolve(fn.ReturnType).Equals(EmType.Bool);

        if (answersOne && !asksQuestion)
            Warn(fn.Name.Line,
                 $"{fn.Name.Lexeme} returns Bool, so its name ends in ? — {fn.Name.Lexeme}?",
                 "A name ending in ? means the answer is yes or no, and the reader learns "
                 + "the return type without looking the method up.");

        if (asksQuestion && !answersOne)
            Warn(fn.Name.Line,
                 $"{fn.Name.Lexeme} ends in ?, so it is expected to return Bool, "
                 + $"not {Resolve(fn.ReturnType).Show()}.",
                 "The ? is a promise about the answer. Drop it, or return Bool.");
    }

    private static string ToSnake(string name)
    {
        var result = new System.Text.StringBuilder();
        for (int i = 0; i < name.Length; i++)
        {
            if (char.IsUpper(name[i]) && i > 0 && name[i - 1] != '_') result.Append('_');
            result.Append(char.ToLowerInvariant(name[i]));
        }
        return result.ToString();
    }

    private static string ToScreaming(string name) => ToSnake(name).ToUpperInvariant();

    private static string ToPascal(string name) =>
        string.Concat(name.Split('_', StringSplitOptions.RemoveEmptyEntries)
                          .Select(part => char.ToUpperInvariant(part[0]) + part[1..]));

    private void Warn(int line, string message, string? hint = null, string? topic = null) =>
        Diagnostics.Add(new Diagnostic(_file, line, message, hint, Severity.Warning, topic));

    private void Error(int line, string message, string? hint = null, string? topic = null) =>
        Diagnostics.Add(new Diagnostic(_file, line, message, hint, Severity.Error, topic));
}
