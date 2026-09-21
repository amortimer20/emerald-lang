# Collections and ranges

This guide covers the syntax and semantics shared by `List[T]`, `Dict[K, V]`, `Set[T]`, and
`Range` — literals, value semantics, indexing, equality, and iteration. Each type's full
method-by-method reference lives in its own library page:
[`List`](../library/list.md), [`Dict`](../library/dict.md), [`Set`](../library/set.md),
[`Range`](../library/range.md). [Tuples](../library/tuples.md) hold a fixed, differently
typed group of values rather than a growable collection of one kind, but share this guide's
equality rule; see their own page for positions and destructuring.

## Which collection a bracket means

Square brackets are the literal for all three collection types. What decides which one a
bracket produces:

```emerald
var scores: List[Int] = [10, 20, 30]
var ages: Dict[String, Int] = ["Ava": 12, "Noah": 13]
var seen: Set[String] = ["red", "green"]
```

A `key: value` entry makes the literal a `Dict`. Otherwise it's a `List`, unless a `Set` is
what's expected at that position — a declaration's annotation, a parameter, or a return type
— since only a bracketed literal takes its kind from context this way; a `List` already
sitting in a binding stays a `List` even where a `Set` is expected (`.to_set()` converts it
explicitly). An **empty** literal needs an explicit type in every case, since it has no
elements or entries to infer one from:

```emerald
var names: List[String] = []
var counts: Dict[String, Int] = []
var seen: Set[String] = []
```

A literal's element type is inferred from its elements when nothing else says it, widening
the same way `[1, 2.5]` already infers `List[Float]`: elements of different but related
classes infer their nearest shared base rather than reporting a mismatch.

```emerald
var pets = [Dog("Rex"), Cat("Tom")]   # List[Animal], with no annotation needed
```

Two classes that share only a trait, with no common base class, still need an explicit
annotation — inferring across a trait would expose only the trait's own contract on the
result, not either class's own members. A dictionary's values and a value-producing
`case`'s arms widen the same way. Run
[`conformance/run/sibling-class-inference.em`](../../conformance/run/sibling-class-inference.em).

Printing is unambiguous even though the literals overlap: a `List` prints as written
(`[1, 2, 3]`), a `Dict` prints its entries (`["Ava": 12]`, or `[:]` empty), and a `Set` prints
in braces (`{"red"}`, or `{}` empty) — so a printed collection always says which of the three
it is. A `Set` literal collapses a repeated element to one; a `Dict` literal repeating a key
whose value is known before the program runs (a literal, or an enum value — numbers compare
by value, so `1` and `1.0` repeat each other) is a checking-time error instead, since a later
entry would just silently replace the earlier one. A key computed at runtime is unrelated: it
can still collide, and the later value wins without moving its position, exactly as an
ordinary bracket assignment does. See
[`conformance/diagnostics/dictionary-duplicate-keys.em`](../../conformance/diagnostics/dictionary-duplicate-keys.em).

## Value semantics

`List`, `Dict`, and `Set` are mutable values, following the same rule structs do (4.3):
assignment and ordinary parameter passing each produce an independent collection, at every
level of nesting, and a `const` collection cannot change at all — neither replaced nor
mutated in place. A copy is a semantic guarantee, not necessarily a physical one: an
implementation may share storage between two copies until one of them actually changes, so
passing a large collection into a function costs nothing unless that function copies it into
a `var` and mutates it.

```emerald
var original = [1, 2, 3]
var copy = original
copy.append(4)
print(original, copy)     # [1, 2, 3] [1, 2, 3, 4] -- independent
```

A `for` loop visits the collection as it was when the loop began; mutating it inside the loop
body never changes what the rest of that same loop visits. See
[`conformance/run/list-values.em`](../../conformance/run/list-values.em) for copies at every
level of nesting, a function returning its own changed copy instead of mutating a read-only
parameter (7.1), and the loop-snapshot rule together in one file.

## Indexing and misses

`List` and `String` indexing is zero-based, with no negative indexing. `Dict` has no
positional index at all; instead, bracket lookup can miss, so it answers with an optional
value, and bracket assignment inserts a new entry or replaces an existing one in place:

```emerald
var score = scores["Ava"].or(0)
scores["Mia"] = 9
```

A `Dict` whose value type is already optional does not produce a nested optional on lookup —
both a missing entry and a stored `nothing` read back as plain `nothing` — so
`contains_key?` is how to tell "absent" from "present but `nothing`" apart (4.5's general
non-nesting rule, not a `Dict`-specific exception). `Set` has no lookup by position or key at
all; ask with `contains?(value)` instead. See [`Dict`](../library/dict.md) and
[`Set`](../library/set.md) for the full indexing and membership vocabulary.

## Equality and order

Each compound type compares itself the way its shape suggests: a `List` compares
element-by-element, in order; a `Set` compares by membership alone; a `Dict` compares by
key/value contents, not insertion order; a tuple compares position by position. Every
recursive comparison uses Emerald's own `==`, all the way down.

`Dict` and `Set` still *preserve* insertion order for iteration and display, even though
order plays no part in equality. Replacing a `Dict` value keeps its entry's position;
removing and reinserting a key moves it to the end. Hash layout is never the source of that
order — it comes from the sequence of insertions the program actually made, so it stays
stable across runs and implementations, unlike the hash values themselves.

## Iteration and ranges

`for` iterates a `List` by element, a `Set` by member, and a `Dict` by each entry as a
destructurable `(key, value)` tuple:

```emerald
for (name, age) in ages {
    print(name, age)
}
```

A range (`1..5` inclusive, `1..<5` exclusive) is what makes a bounded, counting `for` loop
possible, and it's also an ordinary immutable value in its own right: it can be stored in a
binding, passed to a function, returned, and iterated later, not only written directly in a
`for` header. See
[`Range`](../library/range.md) for its own `count`, `empty?()`, `step`, `reverse()`, and
`to_list()`, and [`Int`](../library/int.md) for the `times`/`up_to`/`down_to` counting forms a
range is built from. A range only ever counts upward — a start past its end is simply empty
rather than an error — which is exactly what makes a computed bound like `0..<items.count`
safe to write even when `items` might be empty.
