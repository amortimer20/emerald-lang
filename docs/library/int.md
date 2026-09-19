# Int

`Int` is a checked 64-bit signed integer, `-9223372036854775808` through
`9223372036854775807` (4.2). Every method below that can produce a value outside that range
raises rather than wrapping. Signs never change a number-theory answer: `digits`, `gcd`, and
`lcm` treat a receiver or argument's magnitude only.

Run [`conformance/run/int-methods.em`](../../conformance/run/int-methods.em) for the value
cases below and
[`conformance/run/int-method-errors.em`](../../conformance/run/int-method-errors.em) for
every **Raises** case, each caught as an ordinary `RuntimeError`.

## Shared numeric methods

## abs() -> Int

The absolute value.

**Raises** for the minimum `Int`, since its magnitude does not fit in `Int`.

## clamp(minimum: Int, maximum: Int) -> Int

The receiver, pulled into `minimum..maximum` (inclusive) if it falls outside it.

**Raises** if `minimum` is greater than `maximum` — a reversed interval is a mistake to
report, not to silently swap.

## between?(minimum: Int, maximum: Int) -> Bool

Whether the receiver falls in `minimum..maximum`, inclusive on both ends.

**Raises** under the same reversed-interval rule as `clamp`.

## zero?() -> Bool

## positive?() -> Bool

## negative?() -> Bool

The three sign predicates. `0` answers `zero?` true and both sign predicates false.

## to_string() -> String

The receiver's canonical decimal text, the same text `print` and interpolation display.

## Int-only methods

## even?() -> Bool

## odd?() -> Bool

## multiple_of?(divisor: Int) -> Bool

Whether the receiver divides evenly by `divisor`. A negative divisor is accepted.

**Raises** for a zero divisor.

## digits() -> List[Int]

The receiver's decimal digits, left to right in the order it is written, ignoring sign.
`0.digits()` is `[0]`.

## gcd(other: Int) -> Int

## lcm(other: Int) -> Int

The greatest common divisor and least common multiple, both ignoring sign. `gcd(0, 0)` is
`0`; an `lcm` with `0` is `0`.

**Raises** if the mathematical result cannot fit in `Int` — reachable only from the minimum
`Int`'s asymmetric magnitude or from two large arguments.

## factorial() -> Int

The receiver's factorial. `0.factorial()` is `1`.

**Raises** for a negative receiver, and for a result too large for `Int` (`21!` and above).

## to_float() -> Float

Widens the receiver to the equal `Float` value. This is the explicit spelling of the same
conversion Emerald performs implicitly wherever a `Float` is expected (4.4); reach for it
only when no such context already forces the widening.

## Counting forms

These are 6.4's loop-header forms, also callable directly.

## times { index: Int => ... } -> Nothing

**Callback.** Runs the block once for each `Int` from `0` up to one less than the receiver,
in order, passing the index. `times` always takes a block; there is no bare form. A negative
receiver raises.

## up_to(target: Int) -> Range

## up_to(target: Int) { value: Int => ... } -> Nothing

The method spelling of `receiver..target`: without a block, an inclusive ascending `Range`
you can store, pass, or iterate later; with a block, **Callback**, the same Range run
immediately, once per value in order. A `target` before the receiver counts nothing, exactly
like a reversed range literal.

## down_to(target: Int) -> Range

## down_to(target: Int) { value: Int => ... } -> Nothing

`up_to`'s downward counterpart: without a block, a `Range` that counts from the receiver
down to `target` inclusive; with a block, **Callback**, the same count run immediately. A
`target` past the receiver counts nothing, which is what makes
`(0..<items.count).reverse()`-style patterns safe on an empty collection (6.4).

See [`conformance/run/counting.em`](../../conformance/run/counting.em) and
[`conformance/run/range-values.em`](../../conformance/run/range-values.em) for `times`,
`up_to`, and `down_to` in both forms. `Range`'s own `count`, `empty?()`, `step`, `reverse`,
and `to_list()` are listed against
[`conformance/run/range-values.em`](../../conformance/run/range-values.em) in the
[inventory](inventory.md) and get their own family page in a later slice.
