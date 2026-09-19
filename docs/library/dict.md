# Dict[K, V]

A `Dict[K, V]` maps keys to values and preserves insertion order for iteration and display,
even though equality compares contents rather than order (8.4). A key must have stable
equality and hashing: numbers, `Bool`, `String`, enum values, and tuples or structs built
only from those — never a mutable collection or a class object, and never a NaN `Float`
(directly or nested). Assigning replaces a value in place, keeping its position; removing and
reinserting the same key moves it to the end.

```emerald
var ages: Dict[String, Int] = ["Ava": 12, "Noah": 13]
ages["Mia"] = 9
print(ages["Ava"].or(0))
```

Run [`examples/dictionaries.em`](../../examples/dictionaries.em) and
[`conformance/run/dictionaries.em`](../../conformance/run/dictionaries.em) for the value
cases below,
[`conformance/run/dictionary-keys.em`](../../conformance/run/dictionary-keys.em) for key
eligibility and normalization,
[`conformance/run/dictionary-map-transform.em`](../../conformance/run/dictionary-map-transform.em)
and
[`conformance/run/dictionary-set-filtering.em`](../../conformance/run/dictionary-set-filtering.em)
for the callback vocabulary, and
[`conformance/diagnostics/dictionary-key-eligible.em`](../../conformance/diagnostics/dictionary-key-eligible.em)
and
[`conformance/diagnostics/dictionary-key-type.em`](../../conformance/diagnostics/dictionary-key-type.em)
for key-eligibility and key-type mistakes.

An empty literal needs an explicit type (`var x: Dict[String, Int] = []`), since it has no
entries to infer a type from; a nonempty `key: value` literal infers one. An empty `Dict`
prints as `[:]`.

A literal repeating a key whose value is known before the program runs (a literal or an enum
value — numbers compare by value, so `1` and `1.0` repeat each other) is a checking-time
error: a later entry would just replace the earlier one, so writing both is a mistake to
report rather than resolve silently. A key computed at runtime is unrelated — the checker
cannot see it coming, so it collides silently and the later value wins without moving its
insertion position. See
[`conformance/diagnostics/dictionary-duplicate-keys.em`](../../conformance/diagnostics/dictionary-duplicate-keys.em).

## Size and lookup

## count -> Int

## empty?() -> Bool

`count` is a read-only property (no parentheses).

## dict[key] -> V?

## dict[key] = value

Bracket lookup can miss, so it answers with an optional value; a `Dict` whose own value type
is already optional does not nest, so both a missing entry and a stored `nothing` read as
`nothing` — `contains_key?` is the way to tell them apart. Bracket assignment inserts a new
entry or replaces an existing value in place, keeping its position; storing `nothing` stores
an entry (never a deletion) when the value type allows it.

**Raises** nothing — indexing with a key of the wrong type is a checking-time error (`this is
Int, but the dictionary's keys are String`), not a runtime one.

## contains_key?(key: K) -> Bool

## contains_value?(value: V) -> Bool

## keys() -> List[K]

## values() -> List[V]

## entries() -> List[(K, V)]

`entries()` gives each pair as a destructurable `(key, value)` tuple, in insertion order —
the same shape `for` and every callback below receives.

## remove(key: K) -> V?

Removes the entry for `key` if present and returns its value, or `nothing` if the key was
absent — absence is an ordinary outcome here, not an error.

## merge(other: Dict[K, V]) -> Nothing

Inserts every entry of `other`, in `other`'s order; a key present in both keeps its own
position but takes `other`'s value.

**Changes** `dict[key] = value`, `remove`, and `merge` all need a changeable receiver — a
`const`, a parameter, a loop variable, or a temporary is rejected (4.3, 7.1).

## Dict-shaped transforms

## map_keys { key: K => ... } -> Dict[K2, V]

## map_values { value: V => ... } -> Dict[K, V2]

**Callback.** Each transforms one side of every entry, run once per entry in insertion order,
producing a new `Dict` the same size as the receiver. `map_keys`' produced keys must still be
eligible; a block producing `Nothing` is rejected, since there would be nothing to collect.

## filter { (key, value) => ... } -> Dict[K, V]

## reject { (key, value) => ... } -> Dict[K, V]

**Callback.** The `Bool` predicate receives each entry as a `(key, value)` tuple, runs once
per entry in insertion order, and never changes the receiver. `filter` keeps matching
entries, `reject` keeps the rest — both preserve the `Dict` shape and insertion order of the
entries they keep.

## Vocabulary shared with List and Set

These run the same way as their `List` counterparts (see [`List`](list.md)), except a
callback receives a `(key, value)` tuple for each entry instead of one element, and any
method that would otherwise return a new collection returns a `List` instead, since its
result generally isn't itself dictionary-shaped:

`each`, `each_with_index`, `reverse_each`, `map`, `flat_map`, `filter_map`, `any?`, `all?`,
`none?`, `one?`, `count_where`, `find`, `find_index`.

`find` returns an optional `(key, value)` tuple; `find_index` returns the optional zero-based
position in iteration order, since a `Dict` has no other index to answer with.
