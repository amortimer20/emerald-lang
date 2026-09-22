# Arithmetic operator annotations: design and implementation plan

Status: completed, 2026-09-22. This records the design and implementation sequence that
landed in `d73ede4`, `f2dfac2`, and `2a9676a`. Read AGENTS.md and the current handoff before
starting later related work; repository state takes precedence over remembered conversations.
At the start of Phase 0 and each resumed implementation slice, reread `git status`, the
recent `git log`, relevant diffs, and docs/handoff.md. Other agent work may have landed
since this plan was written. Preserve that work and reconcile it before editing.

## Objective and accepted direction

Make same-type and mixed-type arithmetic available through annotations on ordinary,
uniquely named instance methods. Retire the four prelude arithmetic traits: Addable,
Subtractable, Multipliable, and Divisible. Breaking changes are acceptable for this work.
Keep Equatable, Hashable, Ordered, Textual, and general user-defined traits.

Canonical names are mandatory, not a convention, but only for one specific shape: a
same-type registration whose result type is also the enclosing type (`Self -> Self`) must
be named `add`, `subtract`, `multiply`, or `divide`, matching its operator — and,
conversely, a registration named `add`/`subtract`/`multiply`/`divide` must have exactly
that `Self -> Self` shape. Both directions are declaration-time diagnostics, not style
suggestions: a `Self -> Self` registration under a non-canonical name is rejected, and a
registration named `add`/`subtract`/`multiply`/`divide` with any other operand or result
type is rejected. A same-type registration whose result is *not* `Self` is unaffected by
this rule as long as it avoids the four reserved names — see the Distance carve-out below.
The reason for the mandate is forward compatibility, not just discoverability: a future
nominal arithmetic trait (an eventual `Addable`, once generics or a similar mechanism
exists) can only be satisfied by adopting it with zero code changes if the method it
requires already has this exact shape. Choosing a free name now would mean a rename or
adapter later; this feature should not create that debt while it is still cheap to avoid.

This reservation applies to the name, not to same-type operands in general: a type may
still register a same-type operand under a different, non-canonical name and a different
result type — `Distance / Distance -> Float` (below) is exactly this case. What it may not
do is call that method `divide`, since `divide` is reserved for a same-type registration
that returns `Self`, which a ratio-returning division is not. The overlap rule already
prevents a type from having two same-type registrations for one operator, so this
reservation adds a naming/shape constraint on the one registration a type is allowed to
have for a given symbol and operand type, not a new kind of check. Mixed-type registrations
(operand type different from the enclosing type) are unaffected and remain free to choose
any name and any result type, as elsewhere in this plan. Operator navigation can improve
discoverability further, but remains a separate tooling deliverable rather than an assumed
existing capability. General function and method overloading, union types, implicit user
conversions, and generics are outside this feature.

Proposed spelling, to settle in the design phase:

```emerald
struct Money {
    const amount: Float

    @operator("*")
    func times(quantity: Int): Money {
        return Money(self.amount * quantity)
    }
}
```

`price * 3` and `price.times(3)` should invoke the same implementation. Annotation arguments
are new parser work, not an existing capability: the current annotation parser recognizes
only override, abstract, and test. Keep this a closed built-in annotation feature.

## Phase 0: finish the design before changing behavior

Read rewrite-context sections 4.3/4.4, 7.3/7.5, 10.2/10.7, 11.4/11.5, 16.1, and the
implementation decision table. Check the actual checker and interpreter against the prose.
Prepare a short decision table covering every question below. Recommendations are not
already accepted language rules; obtain user agreement on material semantic choices before
implementing them. Batch those questions rather than asking about routine coding choices.

Recommended baseline:

- Supported annotation symbols are `+`, `-`, `*`, and `/`, given as literal strings.
- Annotated methods take one required parameter, no defaults, and an explicit return type.
- The left operand owns the operation. There is no operand reversal or reflected dispatch.
- A method can return a different type: Matrix times Vector returns Vector; Distance divided
  by Distance can return Float. Return types never choose an implementation.
- Exception: a same-type registration (operand type equals the enclosing type) is bound to
  its result type two ways at once. Named `add`/`subtract`/`multiply`/`divide`, it must
  return `Self` — no other result type is allowed under those names. Returning `Self`, it
  must be named `add`/`subtract`/`multiply`/`divide` — no other name is allowed for that
  shape. A same-type registration returning something other than `Self` must use a
  non-canonical name; see the naming section above.
- Use ordinary argument compatibility, including Int-to-Float widening and subtyping.
- Limit the initial right-hand parameter domain to nonoptional built-in scalar types
  (Int, Float, Bool, String, Bytes) and nominal struct, enum, and class types. Recommend
  deferring trait, optional, collection, tuple, and function operand parameter types,
  rejecting them at the annotation declaration. This is a proposed scope boundary for
  user approval, not an instruction to build a general type-intersection algorithm.
- Reject registrations whose accepted argument types overlap; do not rank candidates.
  In particular, Int and Float registrations overlap because both accept Int.
- Compound assignment uses the selected operation and ordinary assignment compatibility.
  Its result need not be identical to the destination type, but must be assignable to it.
- Preserve existing arithmetic behavior for built-in numbers, String concatenation, and
  Bytes concatenation; the annotation does not add extension methods to built-in types.

Questions that need precise answers:

1. **Overlap:** Confirm the limited parameter domain above. Within it, identical types
   overlap, Int and Float overlap, and class types overlap when one inherits from the other.
   Distinct structs/enums and unrelated class branches are disjoint under current nominal
   typing and single inheritance. Verify these rules against actual assignability before
   adopting them. A concrete class can have subclasses: accepting Animal must accept Dog,
   and registering both must be rejected. Abstract base classes need not be excluded merely
   because they are abstract; the same ancestry rule applies. Do not extend this pairwise
   assignability test to traits: unrelated traits can share implementations. Defer that
   domain rather than solving general intersections as a prerequisite to this feature.
   Keep ordinary call compatibility within the supported domain.
2. **Inheritance:** Recommend inheriting registrations and selecting from the left operand's
   static type, followed by ordinary virtual dispatch of the chosen method. A derived method
   overriding that method must not create a duplicate registration. Decide whether it repeats
   the annotation, whether subclasses may add registrations, and how inherited overlap is
   checked. A subclass-only registration must not become visible through a base-typed value.
   Verified fact, not a recommendation: `Self` is not covariant. `Checker.selfInSignatureOf`
   binds `written_self` once, from the method's own declaring key, to `Type.structOf` of the
   *declaring* type — not the receiver's actual type. If `Animal` declares the canonical
   `add(other: Self): Self` and `Dog` inherits it without overriding, `Self` there still means
   `Animal`: a `Dog` argument is accepted only by ordinary upcast compatibility, and the
   declared result stays `Animal`, not narrowed to `Dog`. This bears directly on the mandatory
   same-type shape above (`add(other: Self): Self`): an inherited canonical registration does
   not automatically become `Dog`-typed just because `Dog` inherited it, so decide here whether
   a subclass needs its own canonical registration to get `Dog`-typed same-type arithmetic, or
   whether the base's stays authoritative for every subclass that does not override it.
3. **Trait placement:** Decide whether user traits may declare annotated requirements/defaults
   in the first slice. A narrower initial choice is annotations only on struct/class methods.
   `Self` already works in ordinary struct/class method parameter and result types without
   trait adoption (Checker.resolveTypeExpression, written_self, and ownSelf). Retiring the
   arithmetic traits does not remove that ability or require a new Self rule. Preserve its
   existing meaning, including inherited signatures; accept the enclosing type's explicit
   name equivalently. The earlier version of this plan incorrectly described Self as
   depending on arithmetic-trait context.
4. **Placement and multiplicity:** Decide visibility requirements, abstract methods, enum
   methods, multiple annotations on one method, and whether one method may implement several
   symbols. Diagnose annotations on free functions, constructors, properties, or type functions.
5. **Mutation and construction:** Audit the actual existing rules for structs versus classes;
   do not silently strengthen them. Preserve constructor restrictions on calls through self,
   operand evaluation order, capture checks, and exclusive-access behavior.
6. **Compound assignment:** State how an indexed/property destination is evaluated once,
   how getters/setters participate, and where a nonassignable result is diagnosed.

Use these examples to validate the design before coding:

| Expression | Intended result or question |
| --- | --- |
| Money * Int | Money; no Money * Money requirement |
| Vector * Float, Vector * Int | Vector, using ordinary numeric widening |
| Matrix * Matrix | Matrix |
| Matrix * Vector | Vector |
| Vector + Vector, named `add(other: Self): Self` | Allowed — canonical name, canonical shape |
| Vector + Vector, named `plus(other: Self): Self` | Declaration-time error — `Self -> Self` shape requires the canonical name |
| Money * Money, named `multiply(other: Self): Int` | Declaration-time error — canonical name requires `Self -> Self`, not a different result type |
| Distance / Distance | Float despite same-type operands; the method must not be named `divide` under the mandatory-name rule above |
| Int * Money | Unsupported unless a future explicit mechanism enables it |
| Matrix *= Vector | Clear error: Vector cannot be assigned back to Matrix |
| Operator expecting Animal, given Dog | Same compatibility as an ordinary method |
| Registrations for Animal and Dog | Declaration-time overlap error |
| Registration with a trait/optional/container parameter | Declaration-time unsupported-operand diagnostic in the proposed initial scope |

Record approved rules in rewrite-context in the same slice that implements them. Until then,
keep alternatives here rather than presenting them as shipped behavior in the baseline.

## Implementation map to verify

- `src/Parser.zig`: parseAnnotations, known_annotations, placement checks, recovery, and
  hardcoded annotation diagnostics. Store symbol and source spans without a general expression
  evaluator for annotation arguments.
- `src/Ast.zig`: method annotation metadata; BinaryOperator.contract and OperatorContract
  currently couple arithmetic to fixed trait/method names. Preserve comparison contracts.
- `src/Formatter.zig`: emit annotations and retain idempotence under both brace styles.
- `src/Resolver.zig`: resolve named methods normally; replace assumptions that arithmetic
  calls fixed method names. Ensure module-read/call facts remain conservative for selected
  methods and overrides. Do not regress uninitialized-capture checking.
- `src/Checker.zig`: collect validated registrations, check overlap/inheritance, select one
  method, check/widen its operand, and retain its result type. Inspect typeOfOperatorCall,
  arithmetic, compound assignments, constructor readiness, and method mutation checks.
- `src/Interpreter.zig`: execute the checker's selected method using existing call machinery.
  Avoid a second runtime overload resolver. Preserve argument/result conversion, receiver
  dispatch, ownership, exceptions, and once-only evaluation of assignment destinations.
- `src/prelude.em`: remove only the four arithmetic traits and their obsolete commentary.
- `src/Type.zig`, `src/Value.zig`, `src/Heap.zig`: inspect assumptions/tests; a new value kind
  or numeric representation should not be needed for this feature.
- `src/Lsp.zig`: verify hover result types and normal navigation/rename for named methods.
  Assess operator-token go-to-definition as a separate deliverable; if included, use the
  checker's selected target. Never claim it works merely because method-name navigation does.

## Runnable implementation slices

1. **One complete annotated operation.** Parse, check, format, and execute Money times Int.
   Include malformed annotation/placement diagnostics and explicit named-call equivalence.
   Temporary coexistence with arithmetic traits is acceptable during development, with no
   ambiguous precedence. Do not expose syntax as complete before it has runtime behavior.
2. **Selection and semantics.** Add multiple disjoint registrations, differing result types,
   conversions, approved inheritance rules, and compound assignments. Test overlap rejection
   and selected-method capture checks. This is the main correctness slice.
3. **Retirement and migration.** Migrate all existing arithmetic examples and conformance
   cases; remove prelude traits, old authorization checks, and stale diagnostic suggestions.
   Remove @override where a method no longer implements a trait, while retaining real
   overrides. Audit trait-typed arithmetic examples rather than mechanically rewriting them.
   User-defined traits with the retired names must no longer receive special operator powers.
4. **Documentation and integration.** Update language/library references, current handoff,
   and the decision table. Preserve historical journal entries. Update fuzz generation if it
   emits the old syntax. Review LSP behavior and all remaining arithmetic-trait references.

Keep each slice runnable; commit only when authorized. Do not push without authorization.

## Completion audit

The four arithmetic authorization traits are retired and maintained examples, diagnostics,
library references, and the decision table use annotations instead. The fuzz generator did not
emit the retired syntax: its valid programs are built-in-only, and its malformed-token stream
does not encode trait declarations, so no generator migration was needed. LSP navigation,
rename, and references continue to target the registered method when that method's name is
used normally. Operator-token go-to-definition is also implemented: binary AST nodes retain
the operator token's span, and the LSP uses the checker's statically selected method key to
resolve a cursor on `+`, `-`, `*`, or `/`. Renaming remains method-name based; an operator
symbol is not an identifier and is therefore not itself renameable.

## Tests and completion criteria

Use backend-neutral run and diagnostic conformance cases plus focused Zig tests where needed.
Read all expected outputs; do not blindly bless generated diagnostics. Cover the design table,
inherited overrides, invalid annotation literals/symbols/signatures, optional operands,
mutation restrictions, thrown errors, and selected-method reads before module initialization.
For compound assignment, use side effects to demonstrate that receivers and indices evaluate
once. Verify existing numeric, String, Bytes, equality, sorting, and hashing cases unchanged.

Follow the pinned toolchain and run tools/check-toolchain.sh. Required final validation:
Debug and ReleaseSafe `zig build test`, `zig build`, then
`bash tools/check-doc-examples.sh`, and `git diff --check`. Report actual results and blockers.
Remove only identified test artifacts, preserving unrelated user changes.

Done means mixed arithmetic works under the approved rules, the four shipped arithmetic
traits are retired, all maintained examples and docs use the replacement, diagnostics teach
the correction, and no ordinary function/method overload sets were introduced.
