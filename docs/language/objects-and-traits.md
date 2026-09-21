# Objects and traits

Emerald has two ways to group state and behavior — structs (values) and classes
(references) — plus traits for composition without class inheritance, and enums for closed
sets of named values. All four brace their bodies; there is no block-free top-level form.

## Structs: values

A struct's fields declare `var` or `const`, exactly like a binding. Without a constructor of
its own, a struct is built by passing one value per field in declaration order; a field with
a default becomes an optional constructor argument, skipped by naming the fields after it:

```emerald
struct Marker {
    var label: String = "here"
    var at: Point
}
Marker(at: Point(1, 2))
Marker("there", Point(0, 0))
```

Assigning or passing a struct copies it — a change on one side is never visible on the
other, at any depth of nesting, including through a field reached by a long path
(`trip.stops[1].y = 8`). A custom constructor replaces the generated one; `self` is the value
being built, every field must be set on every path before the constructor finishes, a field
may be read once it's set, and a `const` field is set exactly once, never inside a loop. A
method that changes a field of `self` can only be called on something that can itself change
(a `var`, not a `const` or a parameter); a method that only reads can be called on anything.
Omitting a method's call parentheses captures it as a value holding its own private copy of
the receiver — calls through that captured value never affect the original. Run
[`examples/structs.em`](../../examples/structs.em) for all of this end to end, including
type-level members and privacy below.

### Properties

A property reads like a field but computes its value:

```emerald
const area: Float {
    return self.width * self.height
}
```

That's the read-only form — `const` with a body, recomputed on every read, never cached. A
writable property uses `var` with explicit `get`/`set` blocks; the setter receives the
proposed value through the read-only name `value`:

```emerald
var diameter: Float {
    get { return self.radius * 2 }
    set { self.radius = value / 2 }
}
```

A field, a property, and a method of one type share one name space, so none of them can
collide with each other. A getter may never change `self` — otherwise reading a property of
a `const` struct would have to be rejected — but a setter changes `self` exactly as an
ordinary changing method does.

### Type-level members

A member declared with the type's own name in front belongs to the type, not to each value,
and is always reached through the type — never through an instance, and never from outside
without naming the type:

```emerald
var Trip.planned = 0

func Trip.home(to: Point): Trip {
    return Trip("home", Point(0, 0), to)
}
```

There is no `static` keyword; the type name in front of the declaration is what marks it. A
type-level field's value is set up lazily, once, the first time the type is constructed or
one of its type-level members is reached. A leading underscore marks any member — field,
property, method, or type-level member — private to code written inside that type's own
braces; equality and display still include a private field, since privacy limits who can
*reach* a member, not what the value is. See the private `Trip._length` helper and the
`Trip.planned`/`Trip.home` type-level members in
[`examples/structs.em`](../../examples/structs.em).

## Classes: shared objects

A class declares the same kinds of members a struct does, but its values are objects:
assigning or passing one shares the same object, so a change through any reference is visible
everywhere that object is held. `const` on a class binding fixes *which* object it refers to,
not the object's own contents — `const mix = Playlist(...)` still lets `mix.add(...)`
through, because the object itself can change. Two class values are equal only when they are
the same object, never by field comparison, even when every field matches. A block written
inside a method may use `self` freely, since the object it closes over is shared rather than
copied. See [`examples/classes.em`](../../examples/classes.em).

### Inheritance

A class extends at most one base class. An override is explicit:

```emerald
@override
func speak() {
    super.speak()
    print("Woof")
}
```

`super.name` reaches the base class's version — of a method, or a property's setter through
`super.name = value` — and `super(...)` may only be a constructor's first statement. A
same-named member *without* `@override` is rejected outright
(`` `speak` is already a method of `Animal` ``) rather than silently shadowing the base
version, since a class shares one set of names — fields, methods, properties, private
members included — with everything it extends. An overriding method must take exactly the
parameters it replaces, with the same names and types, and give back the same type, a
subclass of one the base gives, or a value that's always present where the base gives an
optional. Type-level members are the one exception to all of this: they are not inherited,
and `Animal.count` is reached through `Animal` even from a subclass.

`@abstract` marks a class that exists only to be extended, or a bodyless method within one:

```emerald
@abstract
class Shape {
    @abstract
    func area(): Float
}
```

An abstract class can never be constructed, even if it happens to implement everything —
that's how a base-only class states its purpose on purpose. A concrete subclass must supply
every abstract member it inherits, with `@override` and a body, or the checker names exactly
which ones are still missing. Run
[`examples/inheritance.em`](../../examples/inheritance.em) for a full base/override/`super`
chain, and see
[`conformance/diagnostics/inheritance-construction.em`](../../conformance/diagnostics/inheritance-construction.em)
and
[`conformance/diagnostics/inheritance-overrides.em`](../../conformance/diagnostics/inheritance-overrides.em)
for every mistake above with its exact wording.

## Traits

A trait is a contract, adopted explicitly with `with` — matching members alone is never
enough:

```emerald
trait Describable {
    const name: String

    func details(): String

    func describe(): String {
        return "#{self.name}: #{self.details()}"
    }
}

struct Book with Describable {
    const name: String
    const pages: Int

    @override
    func details(): String {
        return "#{self.pages} pages"
    }
}
```

A signature with no body is a requirement; one with a body is a default the adopter may
leave as-is or replace with `@override`. A `const` requirement accepts a `const`/`var` field
or a readable property; a `var` requirement needs something writable — a `var` field or a
`get`/`set` property — since a writable member satisfies a read-only requirement but never
the reverse. A struct or class's own implementation always wins over a trait default. If two
adopted traits supply the *same* default and the type doesn't resolve it itself, that's a
checking-time ambiguity naming both traits — trait order never silently picks a winner.
`TraitName.method(value)` runs that trait's own default explicitly (useful from inside an
override that wants to extend rather than replace it, as
[`examples/traits.em`](../../examples/traits.em)'s `Song.describe` does); it can only be
*called*, never captured as a value, and has nothing to run for a bodyless requirement. A
trait's own private helper (`_prefix`, say) is reachable only from code written inside that
trait's own braces — not from a type that adopts it, and not from another trait built on it.
`is` tests for a trait and narrows to it, the same as any other type test.

A trait has no stored state, no constructor, and no type-level members; using a trait as a
parameter or binding type exposes only its contract, never changes whether the underlying
value is a copied struct or a shared object, and (for now) cannot be compared with `==`,
since a struct and a class disagree about what equality even means. Run
[`conformance/diagnostics/traits.em`](../../conformance/diagnostics/traits.em) for nearly
every trait mistake in one file — a missing requirement, a wrong type, a read-only field
where `var` is required, a mismatched override signature, an unresolved two-trait conflict,
adopting something that isn't a trait, adopting the same trait twice, a trait that builds on
itself, constructing a trait directly, comparing through one, and reaching a private helper
from outside — each with its exact message.

### `Self`

`Self` means the concrete type adopting the trait, and is written only in a method's or
type-level function's own parameter and result types:

```emerald
trait Addable {
    func add(other: Self): Self
}
```

Inside a trait's own default body, `self` already has type `Self`, so a default can pass
`self` to anything taking `Self`, return it, or compare two `Self` values. Seen through a
value typed as the trait rather than its concrete type, a `Self`-returning member still
answers with the trait type, and a member that *takes* `Self` cannot be called at all — the
value could be any adopting type, and there's no way to prove a caller's value is the same
concrete one.

### Operators

Operators lower to ordinary trait methods, kept discoverable rather than magic:

```emerald
a + b       # a.add(b), via Addable
a < b       # a.compare(b) < 0, via Ordered
```

The overloadable set is narrow on purpose: `+`/`-`/`*`/`/` through `Addable`/`Subtractable`/
`Multipliable`/`Divisible`, and every ordering comparison through one
`Ordered.compare(other: Self): Int` (negative means `self` comes first). `%`, `//`, `**`,
unary `-`, assignment, and boolean short-circuiting are not overloadable, and a type declares
only one `add` — there's no way to separately support `Vector2 + Vector2` and
`Vector2 + Float`; a named method such as `scaled_by` covers the second case. `a += b` lowers
to `a = a + b`. Run [`examples/operators.em`](../../examples/operators.em) for a struct
adopting `Addable`/`Ordered` directly and a trait (`Doubling`) whose own default combines
`Self` values through `+` without knowing the concrete type.

### Display

`Textual` is the prelude trait in the same family, and it decides how a value displays:

```emerald
struct Money with Textual {
    const cents: Int

    @override
    func to_string(): String {
        return "$#{self.cents // 100}"
    }
}
```

`print`, `write`, and interpolation then render the value through that method, and so does
every place it appears — nested in a list, a dictionary, a tuple, a set, or another type's
field-by-field form. What the trait replaces is how the *value* renders, never how a
container frames it, so an adopting value is not quoted the way a nested `String` is:
`[Money(399)]` displays `[$3]`, not `["$3"]`. A type that does not adopt it keeps the
field-by-field form (`Reading(sensor: "north", value: 21.5)`), which is the more useful one
while you are still inspecting a value. Enums adopt it the same way, in place of their
`Enum.value` default.

Adoption is explicit, exactly as for `Addable` or `Ordered`: declaring a method named
`to_string` without `with Textual` leaves the display alone, and the checker warns that it
did. Calling `to_string()` yourself works either way, so `print(x)` and `x.to_string()`
always agree for a type that has the method — the same relationship `Int` and `Float`
already have with their own `to_string()`.

Two details follow from `to_string()` being ordinary code. If it raises, the raise
propagates from the `print` or interpolation that triggered it and is catchable there, and
nothing of the interrupted line reaches the output. If a value reaches itself, the repeat
displays as `Name(...)` rather than running forever, the same guard the field-by-field form
uses. Diagnostics deliberately stay on the field-by-field form — an assertion failure shows
`Point(x: 1)`, never a program's own rendering — so that building a failure message never
runs the program's code. Run [`examples/textual.em`](../../examples/textual.em).

### Custom equality and hashing

A struct compares `==` field by field, and a class compares by identity, by default. Adopt
`Equatable` to replace either with your own rule:

```emerald
class Money with Equatable {
    var cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }

    @override
    func equals(other: Money): Bool {
        return self.cents == other.cents
    }
}

print(Money(500) == Money(500))   # true, not the default identity compare
```

`!=` always follows as `not equals(other)` — there is no separate method to override for it.
Adoption is explicit, exactly as for `to_string`/`Textual` above: declaring `equals` without
`with Equatable` is a warning, and `==` keeps comparing the default way.

A struct that also needs to be a dictionary or set key with this same notion of equality
adopts `Hashable` too, which requires `Equatable` (a trait may build on another, as `Pretty
with Textual` does above) and adds `hash(): Int`:

```emerald
struct CaseInsensitive with Hashable {
    var text: String

    @override
    func equals(other: CaseInsensitive): Bool {
        return self.text.lower() == other.text.lower()
    }

    @override
    func hash(): Int {
        return self.text.lower().count
    }
}

const seen: Set[CaseInsensitive] = [CaseInsensitive("Ada"), CaseInsensitive("ADA")]
print(seen.count)   # 1 — the two collapse under case-insensitive equality
```

Adopting `Equatable` alone does not make a type a key: its default structural hash could
then disagree with a custom `equals`, which is exactly the mismatch that would let a set
hold two "equal" elements as if they were different, so the checker refuses it rather than
silently keeping the old hash. A class stays outside key eligibility either way — adopting
`Hashable` changes what `==` and hashing mean for it, not whether its fields can still
change while it is stored as a key, which is the actual reason classes are excluded (8.3).
Run [`conformance/run/equatable-and-hashable.em`](../../conformance/run/equatable-and-hashable.em).

## Enums

An enum is a closed set of named values, listed first in the declaration, one per line or
comma-separated:

```emerald
enum Weather {
    sunny
    rainy
    snowy
}
```

Each value is a `const` type-level member of the enum, always written with the enum's name —
`Weather.sunny`, even inside the enum's own methods — and enums are eligible dictionary
keys. An enum may have methods, computed properties, and trait conformance, but never stored
instance fields, since there's nothing to construct: an enum value just *is* one of the
listed names. Two enum values compare equal exactly when they're the same name; declaration
order creates no ordering on its own — a `Ordered`-adopting enum states its own order
explicitly, the way any other type would. A value's default display includes its type,
`Weather.sunny`, unless the enum adopts [`Textual`](#display).

`case`/`when` (introduced in [Core language](core.md#control-flow)) is what makes an enum
useful: a value-producing `case` that covers every enum value needs no `else` at all, which
is exactly how `Weather.advice` computes its own text below. Run
[`examples/enums.em`](../../examples/enums.em) for an enum with a computed property built
from an exhaustive `case`, a statement `case` handling only some values, and a subjectless
`case` chosen from ordinary conditions.
