# Random

`Random` is the repeatable form of the randomness prelude describes (9.3, [`prelude`](prelude.md)
for the global `random(range)` and `List`'s own `random()`/`shuffle()`/`shuffle!()`). Two
generators created with the same seed and given the same sequence of operations produce the
same results; the exact sequence is an implementation detail and must not be persisted as a
portable format. Run [`conformance/run/randomness.em`](../../conformance/run/randomness.em)
for every case below alongside the global functions.

## Random(seed: Int) -> Random

Constructs a generator from an `Int` seed. Its state is private.

## next(range: Range) -> Int

Chooses one `Int` from `range`, the seeded equivalent of the global `random(range)`.

**Raises** a `RuntimeError` when `range` is empty (`` `next` cannot choose from an empty
Range ``), the same rule as the global function.

## choose(list: List[T]) -> T?

Chooses one element, `nothing` for an empty `List` — never a raised error, since an empty
collection is an ordinary, expected input here (compare `List.random()`).

## shuffle!(list: List[T]) -> Nothing

Shuffles `list` in place, preserving every element and its multiplicity. A changeable `var`
List is required at check time, since the change must be visible through the same binding —
passing a `const` List or a temporary value is a checking error, not a runtime one.
