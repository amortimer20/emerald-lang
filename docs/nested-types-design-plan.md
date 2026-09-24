# Nested types: design and implementation plan

Status: completed, 2026-09-24. This records the user's direction and the implementation
sequence that landed. It does not authorize implementation, commits, or pushes by itself.
Read AGENTS.md and the current handoff before acting; repository state takes precedence over
remembered conversations. At the start of each slice, reread `git status`, the recent
`git log`, relevant diffs, and docs/handoff.md. Other agent work may have landed since this
plan was written; preserve and reconcile it.

## Objective and accepted direction

Implement section 14.3's nested types, which the spec already describes as settled:

> Nested types are naming and visibility relationships only; they do not capture an
> enclosing class instance. A leading underscore makes a nested type private.

They were never implemented, and until 2026-09-24 nothing recorded the gap. The parser
rejects a type declared inside a type body with a misleading diagnostic ("expected `var` or
`const` for a stored field, found struct"). The immediate consumer is the Console plan's
`Console.Color` (`docs/console-design-plan.md`, decision 1). The later platform libraries
(`Graphics`, `Gui`, `Game`) will want the same shape. The user wants nested types to exist
before Console depends on them.

Out of scope: types declared inside function bodies or other blocks (still rejected, with the
diagnostic fixed in `e9050f6`), inner classes that capture an enclosing instance (14.3 rules
them out), nested types inherited through `extends`, and anything generic.

## Verified machinery (checked against source, 2026-09-24)

- **Keys.** The resolver already uses three separators that cannot appear in a name:
  - `.` for namespace qualification (`Shapes.Circle`);
  - `::` for type members (`Vector2::origin`, `Resolver.method_separator`);
  - `#` for file-private names.

  Keying a nested type as a type-level member, `Paint::Color`, cannot collide with a
  `Color` declared in a `paint/` directory (`Paint.Color`). `Resolver.displayKey` already
  turns `::` back into `.` for anything a reader sees.
- **Type-level members** are registered by `Resolver.hoistTypes` into `facts.type_members`
  (member key → owning type key), `facts.owner`, and `facts.declarations`. Section 10.4
  says they share one name space with the type's fields, properties, and methods, and are
  "always reached through the type, including from the type's own methods." A nested type
  is naturally one more kind of type-level member.
- **Type annotations** are a flat string, `Ast.TypeExpression.name`, possibly dotted.
  `Checker.typeKeyOf` splits at the first `.` only to look up a namespace alias. A
  multi-segment path through a type (`Paint.Color`, `Shapes.Paint.Color`) has no resolution
  path today. `Shapes.Circle` already works as an annotation for a namespaced type.
- **An existing ambiguity with no diagnostic.** A root-level `struct Shapes` and a
  `shapes/` directory can coexist, and the type silently shadows the namespace:
  `Shapes.Circle` reports "`Shapes` has no type-level member named `Circle`." Today that is
  a latent trap. With nested types it becomes two legitimate meanings for one path, so it
  must become an error first (decision 1, slice 0).
- **Display.** Namespaced values display without their namespace: a `Shapes.Circle` prints
  `Circle(r: 1)`, and a `Shapes.Size.large` enum value prints `Size.large`.
- **Type bodies** are parsed by `Parser.parseStructMember`, which today reports anything
  that isn't a member as a missing `var`/`const`. The formatter's
  `Printer.printStructDeclaration` merges members back into source order through its
  `Member` union. LSP `documentSymbols`/`structSymbol` builds children from the same member
  lists.
- The prelude declares built-in namespaces as classes with type-level functions
  (`class File { func File.read(...) }`), so `class Console { enum Color { ... } }` is the
  shape the Console plan needs.

## Decisions (all seven approved by the user, 2026-09-24)

Each recommendation below was approved as written; the alternatives are kept as the record
of what was weighed.

1. **A type and a namespace sharing a name.** Recommended: a declaration error wherever
   both would be reachable by the same name, reported at the type declaration and naming
   the directory. `Shapes.Circle` must mean exactly one thing. Alternative: a fixed
   precedence (type wins, or namespace wins). That keeps a silent shadowing trap, and the
   diagnostic would have to explain a rule the reader cannot see.
2. **Declaration spelling.** Recommended: the bare name, as every mainstream language
   spells it:

   ```emerald
   class Console {
       enum Color {
           red, green
       }
   }
   ```

   10.4's receiver (`func Vector2.origin()`) exists to tell a type-level member from an
   instance member of the same shape. A type is never an instance member, so a receiver
   would distinguish nothing. Alternative: `enum Console.Color { ... }`, spelled the way it
   is used and mirroring 10.4 exactly.
3. **Naming inside the enclosing type.** Recommended: always qualified, `Console.Color`,
   even inside `Console`'s own methods and inside `Color` itself. This is 10.4's rule for
   every type-level member, and section 12's for enum values, which are written
   `Direction.north` "including inside the enum's own methods." Alternative: a bare
   `Color` inside `Console`'s braces. Shorter, but it would be the one type-level member
   reachable unqualified.
4. **Which kinds may contain which.** Recommended: `struct`, `class`, and `enum` bodies may
   declare nested `struct`, `class`, `enum`, and `trait` types, nested to any depth within
   the parser's existing nesting limit. A `trait` body may not contain types in this slice,
   since a trait's body is requirements and defaults, and a nested type there would need
   its own meaning for adopters. An `enum`'s nested types come after its values, like every
   other enum member (12).
5. **Display.** Recommended: a nested type displays with its enclosing types but without its
   directory namespace. `Console.Color.red` prints `Console.Color.red`, and a nested struct
   prints `Outer.Inner(x: 1)`. The nesting is part of the type's own name (14.3 calls it a
   naming relationship), while the namespace is where the file lives, which namespaced
   types already omit. Alternative: the bare `Color.red`, which is consistent with
   namespaced display but makes two different nested `Color`s print identically.
6. **Privacy reach.** Recommended: 10.5's rule unchanged. A private member is reachable
   only from code written inside its own type's braces. A nested type's methods are
   written inside the enclosing type's braces, so they can reach the enclosing type's
   private members; a private nested type `_Inner` is reachable only inside `Outer`'s
   braces. This matches Java and C# nested classes and needs no new rule. It should be
   stated explicitly and tested in both directions, because the enclosing type cannot
   reach the nested type's private members.
7. **`using` and aliases.** Recommended: `using` still takes only namespaces (14.2), never a
   type, so `using Console` does not bring `Color` into scope. An alias may name a nested
   type, as 14.2 already lets it name one declaration:

   ```emerald
   using Color = Console.Color

   print(Console.style("Warning", foreground: Color.yellow, bold: true))
   const highlight: Color = Color.cyan
   ```

   Aliases to a single declaration already work today for namespaced types
   (`using Paint = Graphics.Color`, verified); a nested type only lengthens the path. The
   alias stays file-local and changes no display: under decision 5, `print(highlight)`
   prints `Console.Color.cyan`. A collision with a name the file declares follows 14.2's
   existing rule.

## Specified behavior

- A nested type is keyed `Outer::Inner` (or `Namespace.Outer::Inner`), registered as a
  type-level member of `Outer`, and occupies a name in `Outer`'s one member name space. A
  field, property, method, type-level function or field, or other nested type of the same
  name in `Outer` is a duplicate-name error.
- The type path `Outer.Inner`, in annotations and expressions alike, resolves by:
  namespace prefix (if any), then a type, then zero or more nested type segments, then
  (in expressions only) a type-level member such as an enum value, type-level function, or
  constructor call. `Console.Color.red`, `Console.Color` in an annotation, and
  `Shapes.Paint.Color(…)` construction all follow this one walk.
- `Self` inside a nested type's method means the nested type (it already binds to the
  declaring type through `Checker.selfInSignatureOf`).
- A nested type captures nothing: it cannot use the enclosing type's `self`, instance
  fields, or instance methods except through a value it is given, exactly like a
  top-level type.
- Nested types are not inherited: if `Animal` declares `Inner`, `Dog.Inner` is an error.
  The diagnostic should suggest `Animal.Inner`.
- Type-level setup (10.4, 14.1's lazy rule) is per type: reaching `Outer.Inner` sets up
  `Inner`'s type-level fields, not `Outer`'s, unless one of `Outer`'s own members is
  reached.
- A misplaced type declaration inside a trait body, or in any block, keeps a specific
  diagnostic, and the old "expected `var` or `const`" message never appears for a type
  keyword.

## Implementation map to verify

- `src/Parser.zig`: accept `struct`/`class`/`enum`/`trait` in `parseStructMember` for
  struct/class/enum bodies, respecting the enum-values-first rule and the nesting limit.
  Reject them in trait bodies with a specific diagnostic. Store nested declarations on
  `Ast.StructDeclaration` (a `types` member list).
- `src/Ast.zig`: the nested declaration list, plus any source-order information the
  formatter and LSP need.
- `src/Resolver.zig`: register nested types recursively under `::` keys in `type_members`,
  `owner`, and `declarations`. Extend `qualify` and type-path resolution to walk
  namespace → type → nested type → member. Add the decision 1 clash diagnostic. Private
  nested types use the existing reach rule.
- `src/Checker.zig`: resolve multi-segment type annotations (`typeKeyOf` and its callers),
  duplicate-member checks across the new member kind, `Self` binding inside nested types,
  constructor calls through a path, and the not-inherited diagnostic.
- `src/Interpreter.zig` and `src/Value.zig`: display names per decision 5; per-type
  type-level setup. No new value kind is expected.
- `src/Formatter.zig`: print nested declarations in source order within the enclosing body
  (a new `Member` case), with correct indentation in both brace styles and idempotence.
- `src/Lsp.zig`: document symbols nest child types; hover, go to definition, find
  references, rename, and completion after `Outer.` all cover nested types. Verify each
  rather than assuming name-based navigation carries over.
- `src/prelude.em`: nothing in this plan. The Console slice adds `Console.Color` afterward.

## Runnable implementation slices

0. **Type/namespace name clash.** Done, 2026-09-24. Decision 1 only: the declaration error
   (`Resolver.reportNamespaceClashes`) and `conformance/diagnostics/namespace-clash`,
   covering a root type, a function against a prefix-only namespace, and a type against a
   nested namespace. Recorded in 14.2, the decision table, and the projects guide. Built-in
   names were left alone: `Math` and `Program` already yield to a project namespace of the
   same name while prelude classes such as `File` do not, which is a separate decision.
1. **Parse, format, and resolve.** Done, 2026-09-24. Nested declarations parse in
   struct/class/enum bodies (`Parser.parseNestedType`, inside the existing 256-level
   nesting limit) and format idempotently in both brace styles. Registration is more than
   the plan first said: if the resolver, checker, and interpreter did not also register
   nested types, a nested type's bodies would pass `check` completely unchecked, and the
   formatter would have deleted nested declarations outright. So each stage now recurses
   through `types` under `Outer::Inner` keys: `Resolver.hoistType`/`recordBase`/
   `walkStructDeclaration`, `Checker.registerStruct`/`checkStructBodies` (its base, trait,
   and field helpers now take the key rather than recomputing it from a bare name), and
   `Interpreter.registerStruct`. Nested display names are `Outer.Inner` from the start.
   An enum value records its enum as the declaring file's key map names it (`Color`, or
   `Console::Color` when nested; `Parser.type_path`), since a nested enum's bare name does
   not resolve. A clash with any member of the enclosing type is reported at the nested
   type as "already a member of `Outer`". Paths such as `Console.Color.red` are still
   unresolved (slice 2); today they report "`Console.Color` is an enum, not a value" with
   a suggestion that repeats what was written, which slice 2 must fix. The syntax stays
   undocumented until slice 2.
2. **Use.** Done, 2026-09-24. Type paths in annotations and expressions, construction,
   enum values through a path, `Self`, per-type setup, display, privacy in both directions,
   and the not-inherited diagnostic. Expressions: `Resolver.qualify` descends nested types
   (`descendNested`) after a leading type or after the longest namespace prefix, so
   `Console.Color.red` and `Ui.Console.Pair.Deep(...)` reach `qualifyTypeMember`; a
   qualified chain follows at most `Resolver.max_nested_path` (16) nested types.
   Annotations, `extends`, and `with`: `typeKeyOf` in the resolver and checker splits at the
   longest prefix that is a type and joins the rest with `::`. Aliases:
   `using Color = Console.Color` works through `applyUsing`. Privacy: expressions already
   used 10.5's textual braces check (`Checker.insideType`), which gives decision 6 as is;
   annotations now check each private nested segment (`reportPrivateNestedPath`).
   Settled while implementing: a type-level member of a nested type names that type bare
   in its declaration, as the nested type itself is declared, so `func Pair.zero()` inside
   `Pair` is used as `Console.Pair.zero()`; the parser already required this. A misspelled
   capitalized member now reports "has no nested type named" and lists the public nested
   types, sorted. With paths resolving, the misleading "`Console.Color` is an enum, not a
   value" report for `Console.Color.red` is gone. The LSP answered every hover, definition, references, completion, and
   symbol request over a nested-types project without failing; navigating nested types is
   slice 3.
3. **Tooling.** Done, 2026-09-24. Document symbols nest nested types. Hover needed nothing:
   it reads checked types, which already display as `Console.Pair.Deep`. Go to definition
   reaches every segment of a path: the resolver records only a qualified path's final
   member, so the LSP reads a segment it has no target for as written
   (`chainSegmentTarget`, `typeTargetOf`), in expressions and annotations alike.
   References walk nested bodies, count each segment of a written type or `using` path, and
   no longer count an enum value's synthesized annotation, which had listed every enum
   declaration once per value (top-level enums too). Completion resolves a nested path's key
   and offers nested type names after `Console.`. Two rename bugs that predate nested types
   were fixed on the way, both about aliases: a use spelled through an alias
   (`using Paint = Graphics.Color`, then `Paint`) was rewritten to the new name, which that
   file cannot see, and the `using` path itself was never renamed, leaving the alias
   pointing at nothing. Rename now edits only sites spelled with the declaration's own name
   that do not begin a path with one of the file's aliases, and includes `using` paths; an
   applied rename of a nested enum through an alias of the same spelling was run to confirm
   the result still works. Still true, and not specific to nested types: a file in a
   directory with no `main.em` is its own program (14.1), so navigation from inside
   `ui/console.em` cannot see a sibling `main.em`'s uses.
4. **Documentation and integration.** Done, 2026-09-24. Rewrite-context 14.3 now states the
   rules with a runnable example, 14.2's alias rule names nested types, and the decision
   table has a row. The language guide's objects page has a "Nested types" section linking
   `conformance/run/nested-types`. The fuzzer has a nested-types template. The Console plan
   spells its color type `Console.Color`, after a temporary nested enum in the prelude
   confirmed that prelude-declared nested types resolve like any other.

Status: complete. All five slices landed, `0f939f1` through the documentation commit.

Keep each slice runnable; commit only when authorized. Do not push without authorization.

## Tests and completion criteria

Use backend-neutral run, diagnostics, and format conformance cases, plus focused Zig tests
where needed. Read every expected output by hand. Cover at least:

- nested struct, class, enum, and trait in each allowed container, and depth greater than 1;
- a nested type in a namespaced file reached as `Namespace.Outer.Inner`;
- the type/namespace clash;
- every duplicate-name pairing with fields, methods, properties, and type-level members;
- enum values through a path;
- construction through a path;
- `Self` in a nested type;
- private nested types and private enclosing members reached in both directions;
- `Dog.Inner` not inherited;
- a nested type in a trait body and in a function body, each rejected with its own message;
- display of values and of diagnostics that name nested types;
- formatter idempotence in both brace styles.

Follow the pinned toolchain and run `tools/check-toolchain.sh`. Required final validation:
Debug and ReleaseSafe `zig build test`, `zig build`, `bash tools/check-doc-examples.sh`,
and `git diff --check`. Report actual results and blockers.

Done means 14.3's nested types work as specified and as decided above, every stage from
parser to LSP understands them, no type path can mean two things, and the Console plan can
spell its color type `Console.Color`.
