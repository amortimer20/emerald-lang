# Range

A `Range` is an ordinary immutable value — `1..5` (inclusive) or `1..<5` (exclusive) — that
can be stored, passed to a function, returned, and iterated later, not only written directly
in a `for` header (6.4). It always counts upward; a start past its end is simply empty rather
than an error, which is what makes a computed bound like `0..<items.count` safe on an empty
collection. `Int`'s `up_to`/`down_to` (see [`Int`](int.md)) are the method spellings that
produce a `Range` counting in a chosen direction. Run
[`conformance/run/range-values.em`](../../conformance/run/range-values.em) and
[`conformance/run/counting.em`](../../conformance/run/counting.em) for every case below.

## count -> Int

A read-only property (no parentheses). The number of values the Range visits.

**Raises** when the Range spans the entire `Int` domain end to end, since that count cannot
fit in `Int` itself (`` this Range has too many values for `count` ``) — narrow the Range or
use a larger `step` instead.

## empty?() -> Bool

Whether the Range visits nothing at all — always true for a start past the end, in either
direction.

## step(distance: Int) -> Range

A new Range visiting every `distance`-th value, in the same direction as the receiver;
`distance` is always positive; the Range decides the direction, never the step's sign. A
Range accepts at most one `step`; calling it on a Range that already has one is a checking
error (`` this already has a step ``).

A **literal** `distance` below `1` is a checking-time error. A **computed** one that turns
out to be below `1` raises at runtime instead (`` a step must be at least 1, but this is
{value} ``) — the check cannot see a computed value ahead of time.

## reverse() -> Range

A new Range visiting the same values in the opposite order. `step` and `reverse` apply in
the order written: `(0..10).step(3).reverse()` visits `9, 6, 3, 0`, while
`(0..10).reverse().step(3)` visits `10, 7, 4, 1`.

## to_list() -> List[Int]

Eagerly materializes every value the Range visits, in order, as a `List[Int]`.

**Raises** under the same whole-`Int`-domain condition as `count`
(`` this Range is too large to turn into a List ``), with the same correction: narrow the
Range or use a larger `step`.
