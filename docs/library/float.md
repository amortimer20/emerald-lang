# Float

`Float` is IEEE-754 binary64 (4.2), so it carries the usual signed zero, infinity, and NaN.
An `Int` widens to `Float` wherever a `Float` is expected (4.4); every method here that takes
a numeric argument accepts an `Int` the same way.

Run [`conformance/run/float-methods.em`](../../conformance/run/float-methods.em) for the
value cases below,
[`conformance/run/float-method-errors.em`](../../conformance/run/float-method-errors.em) for
every **Raises** case, and
[`conformance/run/float-display.em`](../../conformance/run/float-display.em) for how a
`Float` prints (a whole value keeps its `.0`, and scientific notation applies below `1e-6` or
at `1e16` and above).

## Type-level constants

## Float.nan -> Float

## Float.infinity -> Float

The two special values, for building or comparing against them directly. NaN answers
`nan?()` true and every other predicate below false; infinity answers `infinite?()` true and
`finite?()` false. `-Float.infinity` is negative infinity.

## Shared numeric methods

## abs() -> Float

The absolute value. `(-0.0).abs()` is `0.0`.

## clamp(minimum: Float, maximum: Float) -> Float

The receiver, pulled into `minimum..maximum` (inclusive) if it falls outside it. A NaN
receiver propagates through unchanged.

**Raises** if `minimum` is greater than `maximum`, or if either bound is NaN.

## between?(minimum: Float, maximum: Float) -> Bool

Whether the receiver falls in `minimum..maximum`, inclusive on both ends. A NaN receiver
answers `false`, since NaN has no order.

**Raises** under `clamp`'s reversed-interval and NaN-bound rules. Infinite bounds are valid.

## zero?() -> Bool

## positive?() -> Bool

## negative?() -> Bool

The sign predicates. Both signed zeros answer `zero?` true. NaN answers all three `false`.

## to_string() -> String

The receiver's canonical decimal text, following the display rules linked above.

## Rounding and conversion

## floor() -> Int

## ceil() -> Int

## round() -> Int

## truncate() -> Int

## to_int() -> Int

Four rounding rules plus the explicit conversion: `floor`/`ceil` round toward negative/
positive infinity, `round` resolves a tie away from zero, and `truncate` and `to_int`
compute the same result (discard the fraction toward zero) but name the operation
differently — `truncate` for the mathematical rounding rule, `to_int` for an explicit type
conversion.

**Raises**, for all five, on NaN, infinity, or a mathematical result outside `Int`'s range.

## round_to(places: Int) -> Float

Rounds to `places` decimal places and returns a `Float`, not text: `2.0.round_to(2)` is the
number `2.0`, not `"2.00"`. Positive `places` addresses digits after the decimal point, `0`
produces a whole-number-valued `Float`, and negative `places` rounds to tens, hundreds, and
so on. Ties round away from zero, matching `round`. Every `Int` place count is accepted:
precision beyond binary64's decimal range leaves a finite value's fractional side unchanged
and produces a signed zero past its whole-number side. NaN and infinity propagate through
unchanged rather than raising.

## Classification

## finite?() -> Bool

## infinite?() -> Bool

## nan?() -> Bool

Exactly one of `finite?()` or `infinite?()`/`nan?()` holds for any `Float`. NaN answers
`finite?` and `infinite?` both `false` and `nan?` alone `true`; infinity is the reverse.

## Receiver-only math

## square_root() -> Float

## to_radians() -> Float

## to_degrees() -> Float

Operations naturally performed by one value, kept as methods rather than moved to `Math`:
the square root, and the two angle-unit conversions `Math`'s trigonometry functions expect
(radians). See
[`conformance/run/float-receiver-math.em`](../../conformance/run/float-receiver-math.em).
Broader numeric operations — trigonometry, logarithms, `pi`, `e`, `power` — live on the
`Math` namespace, its own family page in a later slice.
