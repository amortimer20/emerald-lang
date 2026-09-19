# List[T]

`List[T]` is Emerald's ordered, indexable, growable collection. Elements are compared and
found by value (`Value.equals`, recursive/structural), never identity. Indexing is
zero-based; there is no negative indexing, and slicing a `List` with a range
(`list[1..<3]`) is not implemented — do not write it into an example. There is no `+`/`+=`
concatenation operator on `List`; `chain` is the way to join two.

Run [`conformance/run/lists.em`](../../conformance/run/lists.em) for most cases below,
[`conformance/run/list-values.em`](../../conformance/run/list-values.em) for copy-on-write
value semantics, and the other `conformance/run/list-*.em` files cited per section. Every
example on this page was re-run against the built binary while writing it.

## Size and properties

## count -> Int

## empty?() -> Bool

## first -> T?

## last -> T?

All four are read-only properties (no parentheses) except `empty?()`, which is an ordinary
method; writing parentheses after `count`, `first`, or `last` is a checking-time error.
`first`/`last` are `nothing` for an empty `List` — the optionals rule of 4.5, since a `List`
can hold `nothing` as an element and `first`/`last` must not confuse "empty" with "the first
element happens to be absent." Use `empty?()` to tell the two apart.

## Indexing

## list[index: Int] -> T

## list[index: Int] = value: T

Zero-based read and write, including compound assignment (`list[i] += 1`).

**Raises** for an out-of-range index — the same message family `remove_at` uses below:
`` index {n} is outside this list, which is empty `` for an empty receiver, or
`` index {n} is outside this list, which has {count} element(s) `` otherwise, with help
naming the valid range.

## Basic mutation

## append(element: T) -> Nothing

## insert(index: Int, element: T) -> Nothing

## remove(element: T) -> Nothing

## remove_all(element: T) -> Nothing

## remove_at(index: Int) -> T

## remove_first() -> T

## remove_last() -> T

## clear() -> Nothing

**Changes** all eight need a changeable receiver — a `const`, a struct's `const` field, a
function parameter, a loop variable, or a temporary value is rejected, each with its own
diagnostic (`` `{name}` is a `const`, so its contents cannot change ``, a parameter's "the
change would be lost when the function returns," and a temporary's "the change would be
lost" — 4.3, 7.1).

`insert` accepts any index from `0` through `count` inclusive (`count` appends).
`remove`/`remove_all` match by value and quietly do nothing if the element is absent — no
raise. `remove_at`, `remove_first`, and `remove_last` return the element they removed.

**Raises**: `remove_at` for an index outside `0..<count`, sharing "Indexing"'s exact message
above; `insert` for an index outside `0..count` with its own wording
(`` cannot insert at index {n} in a list of {count} element(s) ``); `remove_first`/
`remove_last` on an empty `List` (`` cannot remove an element from an empty list ``).

## Shape and combination

## chain(other: List[T]) -> List[T]

The receiver's elements followed by `other`'s; `other` must share the element type.

## chunks(size: Int) -> List[List[T]]

Groups the receiver into consecutive pieces of `size`; the last piece may be smaller.

## windows(size: Int) -> List[List[T]]

Every consecutive run of `size` elements, stride 1; empty result if `size` exceeds `count`.

**Raises**, for both `chunks` and `windows`, when `size` is less than `1`
(`` `chunks`/`windows` cannot use size {n} ``).

## pairs() -> List[(T, T)]

Adjacent pairs: `[a, b, c].pairs()` is `[(a, b), (b, c)]` — not every combination, and not
index/value pairs. **A known bug**: calling `pairs()` on an empty `List` crashes the
interpreter outright (an integer-overflow panic in `Interpreter.zig`, not a catchable
`RuntimeError`) rather than returning `[]`. Do not demonstrate `pairs()` on an empty `List`
until that is fixed.

## zip(other: List[U]) -> List[(T, U)]

Pairs elements by position with `other`, truncating to the shorter length.

## Grouping and construction

## partition { item: T => Bool } -> (List[T], List[T])

**Callback.** Splits into `(kept, dropped)` by the block's answer for each item, in order.

## group_by { item: T => K } -> Dict[K, List[T]]

**Callback.** The block's `K` must be dictionary-eligible (8.3). Groups by first-appearance
key order, keeping each item's original order within its group.

## frequencies() -> Dict[T, Int]

Counts occurrences of each value-equal element; `T` must be dictionary-eligible; key order
is first-appearance order.

## to_set() -> Set[T]

Converts to a [`Set`](set.md); `T` must be set-eligible. A repeated element keeps its first
position.

## to_dictionary() -> Dict[K, V]

Only valid when `T` is itself a two-element tuple `(K, V)`; a later duplicate key overwrites
the earlier value but keeps its first insertion position.

**Raises** nothing at runtime — using it on a `List` that is not `(K, V)`-shaped is a
checking-time error pointing to `associate`/`associate_by` below.

## associate { item: T => (K, V) } -> Dict[K, V]

**Callback.** The block returns a whole `(key, value)` entry for each item. Same
duplicate-key rule as `to_dictionary`.

## associate_by { item: T => K } -> Dict[K, T]

**Callback.** The block returns only the key; the item itself becomes the value.

## unique_by { item: T => K } -> List[T]

**Callback.** Keeps the first item for each key, `K` dictionary-eligible, in original order.

## Value transforms

## take(count: Int) -> List[T]

## drop(count: Int) -> List[T]

A `count` beyond the `List`'s length is not an error: `take` returns everything, `drop`
returns `[]`.

**Raises** for a negative `count` (`` `take`/`drop` cannot use count {n} ``).

## reverse() -> List[T]

## reverse!() -> Nothing (**Changes**)

## unique() -> List[T]

## unique!() -> Nothing (**Changes**)

`unique`/`unique!` keep each value's first occurrence, in order.

## sort() -> List[T]

## sort!() -> Nothing (**Changes**)

## sort_by { item: T => K } -> List[T]

Stable sorting. `sort` needs `Int`, `Float`, `String`, or a struct adopting `Ordered`;
`sort_by`'s block returns such a key, computed once per item before sorting. An optional
element or key is rejected at check time, since `nothing` has no order.

**Raises**, for both, when the receiver holds (or a key evaluates to) NaN
(`` `sort` cannot order a List containing NaN ``; `` `sort_by` cannot order a key of NaN ``).

## shuffle() -> List[T]

## shuffle!() -> Nothing (**Changes**)

## random() -> T?

Uses the same runtime-managed generator as the prelude's `random`/[`Random`](random.md).
`random()` is `nothing` for an empty `List`, never a raise — see [`Random`](random.md)'s
`choose` for the seeded equivalent.

## Numeric aggregation

## sum() -> T

`T` must be `Int` or `Float`; an empty `List` sums to `0`/`0.0`.

**Raises** on `Int` overflow (`` `sum` overflows Int while adding {a} and {b} ``).

## average() -> Float?

`T` must be `Int` or `Float`; `Int` elements widen to `Float` for the mean, so
`[1, 2].average()` is `1.5`, never truncated. `nothing` for an empty `List`; NaN and infinity
propagate through ordinary `Float` rules.

## min() -> T?

## max() -> T?

`T` must be `Int`, `Float`, `String`, or an `Ordered` struct, with non-optional elements;
`nothing` for an empty `List`; the first tied extreme wins.

## min_by { item: T => K } -> T?

## max_by { item: T => K } -> T?

**Callback.** The block supplies an ordered key per item; the *item*, not the key, is the
result. Same optional/empty/tie rules as `min`/`max`.

## min_max() -> (T?, T?)

One traversal, same eligibility as `min`/`max`; `(nothing, nothing)` for an empty `List`.

**Raises** on a NaN element or key, with one message shared per pair:
`` `min` and `max` cannot order a List containing NaN `` (also covers a NaN element reached
through `min_max`, though its own wording is `` `min_max` cannot order a List containing
NaN ``), and `` `min_by` and `max_by` cannot order a key of NaN ``.

## Search

## find { item: T => Bool } -> T?

## find_index { item: T => Bool } -> Int?

**Callback.** Both short-circuit on the first accepted item; `find` returns it, `find_index`
returns its position. There is no bare `index_of(element)` on `List` (that name is a
[`String`](string.md) method) — use `contains?` for a plain membership check, since `find(...)
== nothing` cannot tell "not found" from "found `nothing` itself."

## contains?(element: T) -> Bool

Value equality, recursive/structural.

## Callback traversal

All of the following are eager, visit each item left to right exactly once (unless noted),
and never change the receiver.

## each { item: T => ... } -> Nothing

**Callback.** A block whose result would otherwise be unused is a checking-time error.

## each_with_index { item: T, index: Int => ... } -> Nothing

**Callback.** Block takes two parameters: item, then a zero-based index.

## reverse_each { item: T => ... } -> Nothing

**Callback.** Visits last to first.

## map { item: T => U } -> List[U]

**Callback.** A block that produces `Nothing` is a checking-time error, since there would be
nothing to collect.

## filter { item: T => Bool } -> List[T]

## reject { item: T => Bool } -> List[T]

**Callback.** `filter` keeps accepted items, `reject` keeps rejected ones.

## flat_map { item: T => List[U] } -> List[U]

**Callback.** Flattens exactly one level; an empty produced `List` contributes nothing. A
block returning `List[U]?` is a checking-time error — an optional result is not treated as an
empty list.

## filter_map { item: T => U? } -> List[U]

**Callback.** The block returns one optional value per item; present values are kept in
order and `nothing` is dropped. It does not flatten — a block returning `List[Int]?`
produces `List[List[Int]]`. A block that is never optional is a checking-time error pointed
toward `map`.

## take_while { item: T => Bool } -> List[T]

## drop_while { item: T => Bool } -> List[T]

**Callback.** `take_while` returns the matching prefix and stops calling the block at the
first rejection. `drop_while` returns everything from the first rejection onward and never
calls the block again after that point.

## any?/all?/none?/one?/count_where

## any? { item: T => Bool } -> Bool

## all? { item: T => Bool } -> Bool

## none? { item: T => Bool } -> Bool

## one? { item: T => Bool } -> Bool

## count_where { item: T => Bool } -> Int

**Callback.** `any?`, `all?`, and `none?` short-circuit as soon as the answer is decided;
`one?` short-circuits as soon as a *second* accepted item is seen (answering `false` early);
`count_where` always visits every item. An empty `List` answers `false`, `true`, `true`,
`false`, and `0`, in that order.

## Reduction

## reduce(initial: A) { accumulator: A, item: T => A } -> A

**Callback.** `initial` is evaluated once. An empty `List` returns it unchanged without
calling the block; otherwise the block runs once per item, left to right, each result
becoming the next accumulator.

## reduce_right(initial: A) { accumulator: A, item: T => A } -> A

**Callback.** The same shape as `reduce`, visiting from the `List`'s end toward its start.

## Display

A `List` prints the way it is written, elements displayed in turn (`[1, 2, 3]`, `[[1.0], []]`,
`[]`); there is no explicit `to_string()` method — `print` and interpolation display a `List`
directly.
