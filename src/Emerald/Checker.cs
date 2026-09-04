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
    private static readonly Dictionary<string, EmType> Kernel = new()
    {
        ["print"] = EmType.Nothing,
        ["read_line"] = EmType.String,
        ["random"] = EmType.Int,
        ["exit"] = EmType.Nothing,
        ["Error"] = new EmType.Prim("Error"),
    };

    private readonly Stack<EmType> _returnTypes = new();

    /// <summary>
    /// How many loops enclose the statement being checked. Reset across a function
    /// boundary, so `items.each { x => break }` is rejected: the block is a function, and
    /// break cannot leave one. Ruby allows it and the result is a control-flow construct
    /// whose behaviour depends on whether the enclosing call happens to yield.
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

    /// <summary>The file whose top-level statement is being checked, so a diagnostic in a
    /// project of many files names the right one.</summary>
    private string _file = fileName;

    public void Check(List<Stmt> program)
    {
        var globals = new Scope();
        foreach (var (name, ret) in Kernel)
            globals.Declare(name, new EmType.Func([EmType.Any], ret));

        // Built-in modules are ordinary named types to the checker, so Math.sqrt resolves
        // through the same signature table as String.upper.
        foreach (var name in Builtins.Modules.Keys)
            globals.Declare(name, new EmType.Prim(name));

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

            _classes[name] = new ClassInfo(name);
            declaringType[name] = c;
        }

        // An enum is a ClassInfo with a different Kind, so type annotations, Obj values
        // and Colour.RED all resolve through the machinery classes already use. What it
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

    private EmType.Func SignatureOf(Stmt.FuncDecl fn) =>
        new([.. fn.Params.Select(p => Resolve(p.Type))],
            Resolve(fn.ReturnType),
            RequiredCount(fn.Params));

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

        foreach (var member in decl.Members)
        {
            switch (member)
            {
                case Stmt.VarDecl field:
                {
                    var fieldType = field.Type is not null ? Resolve(field.Type) : EmType.Any;
                    if (field.IsStatic) info.StaticFields[field.Name.Lexeme] = fieldType;
                    else info.Fields[field.Name.Lexeme] = fieldType;

                    if (field.Init is not null) info.InitialisedFields.Add(field.Name.Lexeme);

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
                              $"{decl.Name.Lexeme}.{method.Name.Lexeme} already has an "
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

        // A class with no constructor of its own inherits its base's, matching EmClass.
        if (!info.HasConstructor && info.Base is not null)
            info.ConstructorParams = info.Base.ConstructorParams;

        // A struct with no constructor gets one from its fields, in declaration order
        // (§3.2). Close to mandatory rather than a convenience: a struct is immutable, so
        // without a constructor there is no moment at which its fields could ever be given
        // values, and the type is unusable. The design document's own Vector3 sample
        // assumed this and did not compile.
        //
        // Every stored field is a parameter, including one with an initialiser. The
        // alternative — an initialised field drops out of the parameter list — reads well
        // until someone adds an initialiser to an existing field and silently changes the
        // arity of every call. When default parameter values land, a field's initialiser
        // should become that parameter's default, which fixes this additively.
        if (!info.HasConstructor && info.Base is null && decl.Kind == TypeKind.Struct)
            info.ConstructorParams =
                [.. decl.Members.OfType<Stmt.VarDecl>()
                       .Where(f => !f.IsStatic && f.Getter is null)
                       .Select(f => Resolve(f.Type))];
    }

    /// <summary>
    /// An enum's values are constants of its own type, so §3.4's constant casing applies
    /// to them — <c>Colour.RED</c>, not <c>Colour.red</c>. That needs no new rule.
    /// </summary>
    private void CheckEnum(Stmt.EnumDecl decl)
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

        // @mirrors covers the whole type, not each member: a foreign API is mirrored
        // wholesale or not at all, and marking every member would be the ceremony §3.4
        // introduced the attribute to avoid.
        bool wasMirroring = _mirroring;
        _mirroring = Carries(decl.Attributes, "mirrors");

        CheckCasing(decl.Name, "type");

        // `self` is an ordinary binding, which is why `self.name` needs no special node.
        var body = new Scope(scope, functionBoundary: true);
        body.Declare("self", new EmType.Obj(info));

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
                    if (method.Body is not null)
                        CheckCallable(method.Params, method.Body, body, method.Name.Lexeme);
                    break;

                case Stmt.ConstructorDecl ctor:
                    _inConstructor = true;
                    CheckCallable(ctor.Params, ctor.Body, body, "constructor");
                    _inConstructor = false;
                    break;


                case Stmt.ClassDecl nested:
                    CheckClass(nested, scope);
                    break;
            }
        }

        CheckFieldsGetValues(decl, info);

        _mirroring = wasMirroring;
        _currentType = previousType;
    }

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
                       .Where(f => !info.InitialisedFields.Contains(f.Key)
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
                    var tried = AssignedBy(t.Body, assigned);
                    var caught = AssignedBy(t.Handler, assigned);
                    exits.AddRange(tried.Exits);
                    exits.AddRange(caught.Exits);

                    if (!tried.Completes && !caught.Completes)
                        return new Flow(assigned, false, exits);

                    // The try body can fail at any point, so only what the handler also
                    // guarantees survives.
                    assigned =
                        !tried.Completes ? caught.Assigned
                        : !caught.Completes ? tried.Assigned
                        : [.. tried.Assigned.Intersect(caught.Assigned)];
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
        CheckCallable([], property.Getter!, body, property.Name.Lexeme);

        if (property.Setter is null) return;

        var setterScope = new Scope(body, functionBoundary: true);
        setterScope.Declare("value",
                            info.Fields.GetValueOrDefault(property.Name.Lexeme, EmType.Any));
        _returnTypes.Push(EmType.Any);
        CheckBlock(property.Setter, setterScope);
        _returnTypes.Pop();
    }

    private void CheckCallable(List<Param> parameters, List<Stmt> body, Scope outer, string what)
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

        _returnTypes.Push(EmType.Any);
        CheckBlock(body, inner);
        _returnTypes.Pop();
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
            case Stmt.FuncDecl fn: CheckFunc(fn, scope); break;
            case Stmt.ClassDecl c: CheckClass(c, scope); break;
            case Stmt.EnumDecl e: CheckEnum(e); break;

            case Stmt.Throw t:
                TypeOf(t.Value, scope);
                break;

            case Stmt.Assert a:
                Expect(TypeOf(a.Condition, scope), EmType.Bool, a.Condition, "assert",
                       a.Keyword.Line);
                break;

            case Stmt.TryCatch tc:
            {
                CheckBlock(tc.Body, new Scope(scope));
                var handler = new Scope(scope);
                handler.Declare(tc.CaughtName.Lexeme, new EmType.Prim("Error"),
                                line: tc.CaughtName.Line);
                CheckBlock(tc.Handler, handler);
                break;
            }

            case Stmt.Return r:
                if (r.Value is not null) TypeOf(r.Value, scope);
                if (_returnTypes.Count == 0)
                    Error(r.Keyword.Line, "return can only appear inside a function.");
                break;
        }
    }

    /// <summary>
    /// A bare function name as a statement is a call (§3.1). Anything else that merely
    /// computes a value and drops it is a mistake, and saying so catches a whole class
    /// of typos that would otherwise run silently.
    /// </summary>
    private void CheckExpressionStatement(Stmt.ExprStmt statement, Scope scope)
    {
        var type = TypeOf(statement.Expression, scope);

        // At a prompt a bare expression is the request, not a mistake: typing `1 + 1` to
        // see 2 is the whole point of having one. §3.1's rule is about a statement in a
        // program computing something and dropping it, which is a different act.
        if (interactive) return;

        if (statement.Expression is Expr.Variable name)
        {
            if (type is EmType.Func or EmType.Unknown) return;

            Error(name.Name.Line,
                  $"This does nothing — {name.Name.Lexeme} is looked up and thrown away.",
                  $"Did you mean to call it, or to use the value?  var result = {name.Name.Lexeme}");
            return;
        }

        if (statement.Expression is Expr.Binary or Expr.Unary)
            Error(LineOf(statement.Expression), "This does nothing.",
                  "Its result is computed and then thrown away.");
    }

    private void CheckVarDecl(Stmt.VarDecl v, Scope scope)
    {
        EmType inferred = v.Init is null ? EmType.Any : TypeOf(v.Init, scope);
        EmType declared = v.Type is null ? inferred : Resolve(v.Type);

        if (v.Type is not null && v.Init is not null && !declared.Accepts(inferred))
            Error(v.Name.Line,
                  $"{v.Name.Lexeme} is declared {declared.Show()} but is given {inferred.Show()}.",
                  Widening(declared, inferred));

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
                  $"Declare it first: var {target.Name.Lexeme} = ...");
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
                          ? "Emerald strings are not integer-indexed. Use .chars to get characters."
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

            default:
                Error(f.Variable.Line,
                      $"Cannot loop over {iterable.Show()}.",
                      iterable switch
                      {
                          // A dictionary holds pairs, and there is no pair type to give
                          // the loop variable — so it says which half is wanted instead.
                          EmType.Dict => "Walk its keys or its values:  "
                                         + "for key in scores.keys { ... }",
                          EmType.Obj => "A range, a list, and a string can be looped over. "
                                        + "For anything else, expose a list from it.",
                          _ => "Loop over a range (1..5), a list, or a string.",
                      },
                      topic: "loop-over");
                element = EmType.Any;
                break;
        }

        var body = new Scope(scope);
        CheckShadowing(f.Variable, scope);
        body.Declare(f.Variable.Lexeme, element, line: f.Variable.Line);

        _loopDepth++;
        CheckBlock(f.Body, body);
        _loopDepth--;
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

        _returnTypes.Push(EmType.Any);
        int enclosingLoops = _loopDepth;
        _hiddenLoops += enclosingLoops;
        _loopDepth = 0;
        CheckBlock(fn.Body, inner);
        _loopDepth = enclosingLoops;
        _hiddenLoops -= enclosingLoops;
        _returnTypes.Pop();
    }

    private void CheckBlock(List<Stmt> body, Scope scope)
    {
        CheckIndentation(body, _file);
        foreach (var stmt in body) CheckStmt(stmt, scope);
    }

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
    /// What a condition proves about the variables in it. Handles the shapes a beginner
    /// actually writes — <c>x != nothing</c>, <c>x == nothing</c>, and those joined by
    /// <c>and</c>. Anything more elaborate simply narrows nothing, which is safe.
    /// </summary>
    private static Dictionary<string, EmType> Refinements(Expr condition, bool whenTrue, Scope scope)
    {
        Dictionary<string, EmType> result = [];
        Collect(condition, whenTrue, result, scope);
        return result;

        static void Collect(
            Expr expr, bool whenTrue, Dictionary<string, EmType> into, Scope scope)
        {
            switch (expr)
            {
                case Expr.Grouping g:
                    Collect(g.Inner, whenTrue, into, scope);
                    break;

                // `a and b` proves both when true.
                case Expr.Logical { Op.Type: TokenType.And } l when whenTrue:
                    Collect(l.Left, true, into, scope);
                    Collect(l.Right, true, into, scope);
                    break;

                case Expr.Unary { Op.Type: TokenType.Not } u:
                    Collect(u.Right, !whenTrue, into, scope);
                    break;

                // Narrowing strips the ?, rather than widening to "could be anything".
                // Both let `maybe.length` through, which is all v0 originally needed — but
                // only the stripped type still knows it is a Weight, and an operator has to
                // find `add` on it. Any is the fallback for a name that is somehow not in
                // scope; the surrounding code will have reported that already.
                case Expr.Binary b when IsNothingTest(b, out var name, out bool isNotEqual):
                    if (isNotEqual == whenTrue)
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
        Expr.Logical l => LogicalType(l, scope),
        Expr.IfExpr i => IfExprType(i, scope),
        Expr.Lambda l => LambdaType(l, scope),
        Expr.Get g => StaticOf(g.Target, g.Name) ?? OptionalMemberType(g, scope),
        Expr.Call c => CallType(c, scope),
        _ => EmType.Any
    };

    private EmType CheckInterpolation(Expr.Interpolation node, Scope scope)
    {
        foreach (var part in node.Parts) TypeOf(part, scope);
        return EmType.String;
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
        return EmType.Range;
    }

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

        if (a is EmType.Unknown || b is EmType.Unknown) return a is EmType.Unknown ? b : a;
        if (a.Accepts(b)) return a;
        if (b.Accepts(a)) return b;

        Error(LineOf(i.Condition),
              $"The then branch gives {a.Show()} but the else branch gives {b.Show()}.",
              "Both branches of an if expression must produce the same type.");
        return EmType.Any;
    }

    private EmType LambdaType(Expr.Lambda l, Scope scope, EmType? paramHint = null)
    {
        var inner = new Scope(scope, functionBoundary: true);
        foreach (var p in l.Params)
            inner.Declare(p.Name.Lexeme,
                          p.Type is not null ? Resolve(p.Type) : paramHint ?? EmType.Any);

        // A one-expression body is the lambda's value (§3.2).
        if (l.Body is [Stmt.ExprStmt only])
            return new EmType.Func([.. l.Params.Select(_ => EmType.Any)], TypeOf(only.Expression, inner));

        _returnTypes.Push(EmType.Any);
        int enclosingLoops = _loopDepth;
        _hiddenLoops += enclosingLoops;
        _loopDepth = 0;
        CheckBlock(l.Body, inner);
        _loopDepth = enclosingLoops;
        _hiddenLoops -= enclosingLoops;
        _returnTypes.Pop();
        return new EmType.Func([.. l.Params.Select(_ => EmType.Any)], EmType.Any);
    }

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
    /// Only <see cref="PredicateSwallowed"/> reads it, to recognise the one shape the
    /// scanner's rule gets wrong for a reader: <c>n.even?.to_string()</c>, where the ? was
    /// meant to end the name and was taken as the operator.
    /// </summary>
    private Expr.Get? _optionalDot;

    /// <summary>Types a <c>?.</c>'s receiver, remembering that it is one.</summary>
    private EmType ReceiverType(Expr.Get g, Scope scope)
    {
        var previous = _optionalDot;
        _optionalDot = g.Optional ? g : null;
        try { return TypeOf(g.Target, scope); }
        finally { _optionalDot = previous; }
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
              + $"Parenthesise the question to use its answer:  "
              + $"({Source.Of(inner)}?).{outer.Name.Lexeme}"
            : null;

    /// <summary>A member read, with <c>?.</c> handled if that is how it was written.</summary>
    private EmType OptionalMemberType(Expr.Get g, Scope scope)
    {
        var receiver = ReceiverType(g, scope);

        if (!g.Optional) return MemberType(receiver, g.Name, scope);

        return CheckedOptional(receiver, g)
            ? EmType.Nullable(MemberType(receiver.Stripped, g.Name, scope))
            : MemberType(receiver, g.Name, scope);
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

    private EmType MemberType(EmType receiver, Token name, Scope scope)
    {
        if (receiver is EmType.Unknown) return EmType.Any;

        // A bare `arr.count` is a zero-argument call, so it resolves the same way
        // `arr.count()` does — parens are optional when nothing is passed (§3.1).
        if (receiver is EmType.Lst list)
            return ListMemberType(list, name, EmType.Any, EmType.Any);

        if (receiver is EmType.Dict dict) return DictMemberType(dict, name, null, scope);
        if (receiver is EmType.SetOf set) return SetMemberType(set, name, null, scope);

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
            Error(name.Line,
                  $"This is {receiver.Show()}, not {receiver.Stripped.Show()}, so {name.Lexeme} may not exist.",
                  $"{Article(receiver.Show())} {receiver.Show()} holds either {Article(receiver.Stripped.Show()).ToLowerInvariant()} {receiver.Stripped.Show()} or nothing. "
                  + "Check it first, or supply a fallback with .or(...)",
                  topic: "maybe");
            return EmType.Any;
        }

        // An enum value carries a name and nothing else. Checked before the class path,
        // since an enum has no fields or methods of its own to find.
        if (receiver is EmType.Obj { Info.Kind: TypeKind.Enum } enumValue)
        {
            if (name.Lexeme is "name" or "to_string") return EmType.String;

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
            {
                // A bare name is a zero-argument call (§3.1), so it wants whichever
                // version takes none — not simply the first one declared.
                var nullary = overloads.FirstOrDefault(f => f.LeastArgs == 0);
                if (nullary is not null) return nullary.Return;

                Error(name.Line,
                      $"{obj.Info.Name}.{name.Lexeme} takes arguments, but got none.",
                      "It has " + string.Join(", and ", overloads.Select(
                          f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".");
                return EmType.Any;
            }

            Error(name.Line, $"No member named {name.Lexeme} on {obj.Info.Name}.",
                  PredicateSwallowed(name, obj.Info.MemberNames())
                      ?? Suggest(name.Lexeme, obj.Info.MemberNames()));
            return EmType.Any;
        }

        // A bare name is a zero-argument call (§3.1), so a method that needs a block was
        // reached without one — it would run nothing, silently. The same shape as bare
        // `exit` doing nothing, which was a real bug once.
        if (Signatures.SignatureOf(receiver, name.Lexeme) is { } signature
            && (signature.WantsBlock || signature.Takes.Length > 0))
        {
            Error(name.Line,
                  signature.WantsBlock
                      ? $"{receiver.Show()}.{name.Lexeme} needs a block."
                      : $"{receiver.Show()}.{name.Lexeme} takes "
                        + $"{Count(signature.Takes.Length, "argument")}, but got none.",
                  signature.WantsBlock
                      ? $"Write what to do each time:  {name.Lexeme} {{ i => ... }}"
                      : $"It wants {string.Join(", ", signature.Takes.Select(t => t.Show()))}.");
            return signature.Returns;
        }

        if (Signatures.TryLookup(receiver, name.Lexeme, out var result)) return result;

        Error(name.Line, $"No method named {name.Lexeme} on {receiver.Show()}.",
              PredicateSwallowed(name, Signatures.MethodsOn(receiver))
                  ?? Suggest(name.Lexeme, Signatures.MethodsOn(receiver)));
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

        List<EmType> given = [.. c.Args.Select(arg => TypeOf(arg, scope))];
        if (c.Trailing is not null) TypeOf(c.Trailing, scope);
        return NonMemberCallType(c, given, scope);
    }

    /// <summary>
    /// A call whose receiver is already resolved. Split out so <c>?.</c> can hand it the
    /// stripped type and wrap what comes back, without every exit here having to know.
    /// </summary>
    private EmType MemberCallType(EmType receiver, Expr.Call c, Expr.Get get, Scope scope)
    {
        {
            if (receiver is EmType.Lst list) return ListCallType(list, c, get.Name, scope);
            if (receiver is EmType.Dict dict) return DictMemberType(dict, get.Name, c, scope);
            if (receiver is EmType.SetOf set) return SetMemberType(set, get.Name, c, scope);

            List<EmType> args = [.. c.Args.Select(arg => TypeOf(arg, scope))];
            if (c.Trailing is not null) TypeOf(c.Trailing, scope);

            // A user-declared method carries real parameter types. A built-in one lives in
            // the return-type table, which records what it gives back and not what it
            // takes, so there is nothing there to check a call against.
            if (receiver is EmType.Obj obj
                && obj.Info.FindMethods(get.Name.Lexeme) is { Count: > 0 } candidates)
            {
                CheckVisibility(obj.Info, get.Name);
                string what = $"{obj.Info.Name}.{get.Name.Lexeme}";

                if (candidates.Count == 1)
                    return CheckArguments(candidates[0], c, args, what, get.Name.Line);

                int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);
                var chosen = candidates.FirstOrDefault(f => Fits(f, supplied, args));
                if (chosen is not null) return chosen.Return;

                Error(get.Name.Line,
                      $"No version of {what} takes "
                      + (args.Count == 0
                            ? "no arguments."
                            : $"({string.Join(", ", args.Select(t => t.Show()))})."),
                      "It has " + string.Join(", and ", candidates.Select(
                          f => $"({string.Join(", ", f.Params.Select(t => t.Show()))})")) + ".");
                return EmType.Any;
            }

            // A built-in has a signature now too, so the standard library is checked the
            // same way the program is.
            if (Signatures.SignatureOf(receiver, get.Name.Lexeme) is { } builtin)
                return CheckBuiltinCall(builtin, c, args, receiver, get.Name);

            return MemberType(receiver, get.Name, scope);
        }
    }

    /// <summary>A call that is not a method call: a constructor, a name, an expression.</summary>
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

        var callee = TypeOf(c.Callee, scope);
        if (callee is EmType.Unknown) return EmType.Any;

        if (callee is EmType.Overloads alternatives)
        {
            string overloaded = c.Callee is Expr.Variable which ? which.Name.Lexeme : "This";
            int supplied = c.Args.Count + (c.Trailing is null ? 0 : 1);

            // At most one can match: §3.2 refused any pair a call could not tell apart, so
            // there is no "best match" rule here and none to explain to anyone.
            var chosen = alternatives.Alternatives.FirstOrDefault(f => Fits(f, supplied, given));
            if (chosen is not null) return chosen.Return;

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

        // Kernel functions are declared with a single Any parameter and skipped, since
        // v0's signatures cannot express read_line's optional prompt.
        if (c.Callee is Expr.Variable v && Kernel.ContainsKey(v.Name.Lexeme)) return fn.Return;

        string name = c.Callee is Expr.Variable named ? named.Name.Lexeme : "This";
        return CheckArguments(fn, c, given, name, LineOf(c.Callee));
    }

    /// <summary>
    /// A call to a built-in method. Separate from <see cref="CheckArguments"/> because a
    /// block is not an argument in the sense the parentheses mean — <c>5.times { }</c>
    /// passes none and one — so the two counts have to be kept apart.
    /// </summary>
    private EmType CheckBuiltinCall(
        Signatures.Signature signature, Expr.Call c, List<EmType> given,
        EmType receiver, Token name)
    {
        string what = $"{receiver.Show()}.{name.Lexeme}";

        if (given.Count != signature.Takes.Length)
            Error(name.Line,
                  $"{what} takes {Count(signature.Takes.Length, "argument")}, "
                  + $"but got {given.Count}.",
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
        EmType.Func fn, Expr.Call c, List<EmType> given, string what, int line)
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

            Error(LineOf(c.Args[i]) is var at && at > 0 ? at : line,
                  $"{what} expects {fn.Params[i].Show()} "
                  + $"{Ordinal(i)}, but this is {given[i].Show()}.",
                  Widening(fn.Params[i], given[i]),
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

    /// <summary>"a" or "an" — small, but a diagnostic that says "A Int" reads as careless.</summary>
    /// <summary>"1 argument" not "1 argument(s)" — small, but "(s)" reads as unfinished.</summary>
    private static string Count(int n, string noun) =>
        n == 1 ? $"1 {noun}" : $"{n} {noun}s";

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
                      "Emerald strings are not integer-indexed. Use .chars to get characters.",

                  // A set has no positions — membership is the question it answers.
                  EmType.SetOf => "A set has no order to index into. Ask whether it holds "
                                  + "something with .contains?, or take .to_list first.",

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
                "union" or "intersect" or "difference" or "subset_of?" => set,
                _ => null,
            };

            if (wanted is not null && given.Count > 0 && !wanted.Accepts(given[0]))
                Error(name.Line,
                      $"{name.Lexeme} on {set.Show()} takes {wanted.Show()}, "
                      + $"but this is {given[0].Show()}.",
                      Widening(wanted, given[0]));

            if (call.Trailing is { } block && name.Lexeme == "each")
            {
                var inner = new Scope(scope, functionBoundary: true);
                if (block.Params.Count > 0)
                    inner.Declare(block.Params[0].Name.Lexeme, set.Element);

                _returnTypes.Push(EmType.Any);
                CheckBlock(block.Body, inner);
                _returnTypes.Pop();
            }
            else if (call.Trailing is not null) TypeOf(call.Trailing, scope);
        }

        return name.Lexeme switch
        {
            "count" => EmType.Int,
            "empty?" or "contains?" or "subset_of?" => EmType.Bool,
            "to_list" => new EmType.Lst(set.Element),
            "union" or "intersect" or "difference" => set,
            "add" or "remove" or "clear" or "each" => EmType.Nothing,

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

            // each { key, value => ... } — the block's parameters come from the
            // dictionary, which is the same contextual typing a list block gets.
            if (call.Trailing is { } block && name.Lexeme == "each")
            {
                var inner = new Scope(scope, functionBoundary: true);
                if (block.Params.Count > 0)
                    inner.Declare(block.Params[0].Name.Lexeme, dict.Key);
                if (block.Params.Count > 1)
                    inner.Declare(block.Params[1].Name.Lexeme, dict.Value);

                _returnTypes.Push(EmType.Any);
                CheckBlock(block.Body, inner);
                _returnTypes.Pop();
            }
            else if (call.Trailing is not null) TypeOf(call.Trailing, scope);
        }

        return name.Lexeme switch
        {
            "count" => EmType.Int,
            "empty?" => EmType.Bool,
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
        Error(name.Line, $"No method named {name.Lexeme} on {on}.",
              Suggest(name.Lexeme, candidates));
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
        foreach (var arg in c.Args) TypeOf(arg, scope);

        EmType blockReturn = EmType.Any;
        if (c.Trailing is not null)
        {
            var hint = Signatures.TakesElementBlock.Contains(name.Lexeme) ? list.Element : null;
            if (LambdaType(c.Trailing, scope, hint) is EmType.Func f) blockReturn = f.Return;
        }

        return ListMemberType(list, name, blockReturn,
                               c.Args.Count > 0 ? TypeOf(c.Args[0], scope) : EmType.Any);
    }

    /// <summary>
    /// Shared by <c>arr.count</c> and <c>arr.count()</c>, which are the same thing —
    /// parens are optional when there is nothing to pass (§3.1).
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
            "map" => new EmType.Lst(blockReturn),
            "filter" or "reject" or "sort" or "sort_by" or "reverse" => list,

            // These can miss, so they give back a maybe and the checker insists you deal
            // with it. The clearest place the nullability design earns itself.
            "find" or "first" or "last" or "min" or "max" => EmType.Nullable(element),

            "index_of" or "count" or "sum" => EmType.Int,
            "contains?" or "any?" or "all?" or "empty?" => EmType.Bool,
            "join" => EmType.String,
            "reduce" => firstArg,

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
              actual.IsMaybe ? "Check it against nothing first." : null);
    }

    private static string? Widening(EmType declared, EmType actual) =>
        declared.Stripped.Accepts(actual.Stripped) && actual.IsMaybe && !declared.IsMaybe
            ? $"Declare it as {declared.Show()}? if it can be nothing."
            : null;

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
        _ => 0
    };

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
    /// Two casings, one statable rule: types are capitalised, nothing else is. Warnings
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
                     $"Rename it to {ToPascal(bare)}. Types are capitalised; nothing else is.",
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
                 $"Rename it to {ToSnake(bare)}. Capitalised names mean types in Emerald.",
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
