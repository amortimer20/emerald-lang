# Types and optionals

[Core language](core.md) introduced `var`/`const`, the initial value types, and mentioned
that a trailing `?` marks a value that may be absent. This guide goes deeper: how Emerald
relates types to each other, what `is` and `type_name` do, and the small, deliberate optional
vocabulary that replaces null references.

## Numeric widening and explicit conversion

An `Int` widens to `Float` automatically wherever a `Float` is expected — an arithmetic
operand beside a `Float`, an assignment to a `Float`-typed place, a `Float` argument or
return, or an element of a literal whose element type is `Float`. It is the *only* implicit
conversion, and it always genuinely converts: `var rate: Float = 1` holds and prints `1.0`.

```emerald
var count = 3
var rate: Float = count      # 3.0
```

Every other conversion is explicit, and Emerald names the family consistently by what it
does on failure: `to_int()` raises, `to_int_or(0)` supplies a fallback, `to_int_maybe()`
answers `Int?`. `Float` has the matching `to_float`/`to_float_or`/`to_float_maybe`. See
[`String`](../library/string.md#parsing) for the full parsing family.

Mixed `Int`/`Float` comparison compares the two numbers' actual mathematical values, not the
`Int` widened into `Float` first — a large `Int` may lose precision when widened, and that
loss must never make two genuinely different numbers compare equal by accident.

## Invariance and widening

Collections are invariant: `List[Int]` is not assignable to `List[Float]`, even though `Int`
widens to `Float` on its own, because a `List` can be written through later. A tuple is
different — it widens position by position, since it cannot be written through the same way
— so a `(Int, Int)` is assignable where `(Float, Int)` is expected. See
[Tuples](../library/tuples.md#widening).

## `is` and `type_name`

`is` tests a value's runtime type and narrows a name within the branch that proves it. Every
value carries a read-only `type_name` reflecting its concrete type in Emerald's own spelling,
including collection and function types (`List[Int]`, `func(Int): String`):

```emerald
if pet is Dog {
    print(pet.fetch())   # `pet` is a `Dog` here
}
print(pet.type_name)
```

`is` binds like a comparison and does not itself chain with one — write `not (value is Dog)`
for a failed test — but `and`/`or` compose with it normally, checking their right side
knowing the left side's test already held (for `and`) or failed (for `or`):

```emerald
if maybe != nothing and maybe is Dog and maybe.tricks > 0 {
    return maybe.fetch()
}
```

`type_name` is reserved: no type may declare a member with that name, and it cannot be
assigned. A test that static analysis can already answer before the program runs (`x is Int`
when `x`'s declared type is already `Int`) still evaluates its operand exactly once and
returns the correct `Bool` — Emerald's plan is to also warn about a result the reader could
already see, but diagnostics have no severity levels yet, so today that specific case prints
nothing extra. Run
[`conformance/run/type-tests.em`](../../conformance/run/type-tests.em) for the full picture:
class hierarchies, tuples, function types, collections, `nothing`/`Nothing`, and evaluating
the tested expression only once even when a block runs a visible side effect.

### Narrowing has a lifetime

Only a name is narrowed — testing `container.value is Dog` proves nothing about
`container.value` afterward, only a bare local or module name. And narrowing lasts only as
long as nothing could have changed what the name holds:

- **Reassignment inside the same branch un-proves it immediately**, even before the branch
  ends: `if pet is Dog { pet = Animal(); pet.tricks }` fails, because `pet` no longer holds
  what the test proved by the time it's read. See
  [`conformance/diagnostics/narrowing-invalidated-by-assignment.em`](../../conformance/diagnostics/narrowing-invalidated-by-assignment.em).
- **A block that captures a variable the surrounding code can still reassign loses the
  narrowing inside the block**, since the block might run after that reassignment — testing
  again *inside* the block narrows it there instead. This applies equally to an `is` test and
  to a `!= nothing` test: see
  [`conformance/diagnostics/narrowing-lost-to-block.em`](../../conformance/diagnostics/narrowing-lost-to-block.em)
  and
  [`conformance/diagnostics/optional-narrowing-lost.em`](../../conformance/diagnostics/optional-narrowing-lost.em)
  (where merely *calling* the block, before ever reading the variable again, is what
  invalidates the earlier `!= nothing` proof).
- **A module-level variable that any function, method, constructor, or accessor assigns is
  never narrowed at all** — any call between the test and the use could be the one that
  changes it. Binding it to a local (or reading it into a `const`) makes the proof explicit
  and stable. See
  [`conformance/diagnostics/narrowing-lost-to-function.em`](../../conformance/diagnostics/narrowing-lost-to-function.em).
- **`const` bindings and read-only parameters keep their narrowing**, since nothing can
  rebind them, and a loop body that doesn't undo a narrowing keeps it on the next iteration.
  See [`conformance/run/narrowing-through-loops.em`](../../conformance/run/narrowing-through-loops.em).

## Optionals

A trailing `?` on a type says the value may be `nothing`: `Int?`, `List[String]?`. It is a
single, non-extensible relationship — user code cannot define its own `?`-like type
constructor — and **optionals never nest**: `Int??` is a checking-time error
(`` a type cannot be optional twice ``), not a special case of anything else. An operation
that would otherwise stack a second layer of optionality just returns the same one-layer type
instead.

Comparing a name against `nothing` narrows it to its non-optional type in the branch that
proves it, following exactly the rules above (reassignment, a capturing block, or a
module-level variable any function can touch all end the narrowing the same way `is` does).
`.or(fallback)` is the other way out — it never needs a proof, because supplying the
fallback *is* the proof:

```emerald
var score = text.to_int_maybe()
var usable = score.or(0)

if score != nothing {
    print(score + 1)
}
```

### Optional chaining

`?.` reaches through one possibly-absent link at a time — a field, a computed property, or a
method call:

```emerald
var city = user?.address?.street.or("Unknown")
```

If the receiver is `nothing`, the whole access short-circuits to `nothing` without
evaluating a method call's arguments; if the receiver is present, the result becomes
optional even though the field or method itself is not. Each possibly-absent link needs its
own `?.` — a single `?.` does not make the rest of a chain implicitly optional, so
`user?.address.city` is rejected when `address` is itself optional (write the second `?.`).

`?.` is read-only: assigning through a chain (`user?.name = "Ava"`) is a checking-time error,
since it would hide whether the assignment actually happened. Calling a **changing** method
through `?.` looks like the same restriction but is enforced differently: it type-checks —
the checker doesn't reject it statically — and only raises a `RuntimeError`
(`` an optional chain cannot call a changing method ``) the moment the chain actually runs
with a present receiver. An absent receiver never reaches that check at all, since the whole
chain short-circuits first. The correction is the same either way: check the receiver
against `nothing` explicitly, then call the changing method with plain `.`.

### The one honest cost

Because optionals never nest, an operation that reports absence through `nothing` cannot
distinguish "there is no answer" from "the answer itself was `nothing`," when the collection
holds optional elements. Every affected operation has an unambiguous companion instead of a
second layer of optionality:

| Lossy on optional elements | Unambiguous companion |
| --- | --- |
| `list.find { ... }` | `list.find_index { ... }` — an index is never `nothing` |
| `list.first`, `list.last` | `list.empty?()` |
| `dict[key]` | `dict.contains_key?(key)` |
| `list.min`, `list.max` | `list.empty?()` |

This is rare enough in beginner code that the companion is worth reaching for rather than
adding nesting. See [`List`](../library/list.md) and [`Dict`](../library/dict.md) for each
method's own optional-result documentation.
