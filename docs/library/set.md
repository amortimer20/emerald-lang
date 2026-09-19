# Set[T]

A `Set[T]` records whether it has seen each of its elements, once, in the order it first saw
them — insertion order for iteration and display, though equality compares membership rather
than order (8.4). An element needs the same stable-equality eligibility as a `Dict` key
(8.3): numbers, `Bool`, `String`, enum values, and tuples of those — never a mutable
collection or a class object, since something that could change after it is stored could
never be found again.

```emerald
var seen: Set[String] = []
seen.add("red")
seen.add("red")
print(seen, seen.count)
```

A bracketed literal becomes a `Set` only where a `Set` type is expected — a declaration
annotation, a parameter, or a return type; a literal with no such expectation is a `List`,
and `.to_set()` (see [`List`](list.md)) converts one explicitly. Repeated elements in a set
literal collapse to one. A `Set` displays with braces, `{"red"}`, and an empty one as `{}`.

Run [`examples/dictionaries.em`](../../examples/dictionaries.em) for `add`/`contains?`/
`to_set()`,
[`conformance/run/set-operations.em`](../../conformance/run/set-operations.em) for set
algebra,
[`conformance/run/dictionary-set-filtering.em`](../../conformance/run/dictionary-set-filtering.em)
for the callback vocabulary shared with `Dict`, and
[`conformance/diagnostics/set-eligible.em`](../../conformance/diagnostics/set-eligible.em),
[`conformance/diagnostics/set-has-no-keys.em`](../../conformance/diagnostics/set-has-no-keys.em),
and
[`conformance/diagnostics/set-literal-needs-set-type.em`](../../conformance/diagnostics/set-literal-needs-set-type.em)
for the checking-time mistakes below.

## Size and membership

## count -> Int

## empty?() -> Bool

`count` is a read-only property (no parentheses). A `Set` has no bracket lookup — indexing
one is a checking-time error (`a set has no keys to look up`) pointing at `contains?`
instead.

## contains?(value: T) -> Bool

## add(value: T) -> Nothing

## remove(value: T) -> Nothing

`add` inserts `value` if it is not already present (an equal element already present is left
untouched, at its original position); `remove` deletes `value` if present. Both quietly do
nothing when the requested change is already true — adding an existing element, or removing
one that was never there — the same forgiving rule `List.remove` uses.

**Changes** both need a changeable receiver — a `const`, a parameter, a loop variable, or a
temporary is rejected (4.3, 7.1). See
[`conformance/diagnostics/const-dictionary-mutation.em`](../../conformance/diagnostics/const-dictionary-mutation.em)
for the shared `const`-collection diagnostic.

## Set algebra

## union(other: Set[T]) -> Set[T]

## intersection(other: Set[T]) -> Set[T]

## difference(other: Set[T]) -> Set[T]

## symmetric_difference(other: Set[T]) -> Set[T]

Ordinary set operations: everything in either set; only what both share; everything in the
receiver but not `other`; everything in exactly one of the two. None changes either operand.

## subset?(other: Set[T]) -> Bool

## superset?(other: Set[T]) -> Bool

## disjoint?(other: Set[T]) -> Bool

Whether the receiver's every element is in `other`; whether the receiver holds every element
of `other`; whether the two share nothing.

## Vocabulary shared with List and Dict

These run the same way as their `List` counterparts (see [`List`](list.md)): `each`,
`each_with_index`, `reverse_each`, `map`, `flat_map`, `filter_map`, `any?`, `all?`, `none?`,
`one?`, `count_where`, `find`, `find_index`, `filter`, `reject`. A callback receives one
member, exactly like a `List` element. `filter`/`reject` preserve the `Set` shape; every
other method in this group returns a `List`, since its result generally is not itself a
valid `Set` (an order-sensitive or possibly-duplicate result). `find` returns an optional
member rather than an optional tuple.

`sum`, `average`, `min`, `max`, and sorting are not defined on `Set` directly. `map`'s result
is already a `List`, so `values.map { value => value }` (or any more useful transform) reaches
[`List`](list.md)'s vocabulary from there; a `for` loop that appends into a `var List` works
the same way.
