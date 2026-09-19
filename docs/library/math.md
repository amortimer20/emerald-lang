# Math

`Math` is a built-in namespace for numerical operations broader than one `Float`'s own
methods (`square_root`, `to_radians`, `to_degrees` — see [`Float`](float.md)). Every function
takes and returns `Float`, accepting an `Int` argument through ordinary widening (4.4);
angles are radians. A project that declares its own `Math` namespace keeps ownership of that
name, and the built-in one steps aside.

`Math` follows ordinary IEEE `Float` results rather than raising: an inverse-trigonometric
input outside its real domain, a negative logarithm, an invalid logarithm base, or a negative
base raised to a non-integral power all produce `NaN`, and `natural_log(0)` produces
`-Infinity`. Inspect these with `nan?()`/`infinite?()` (see [`Float`](float.md)) rather than
`catch`. Run [`conformance/run/math.em`](../../conformance/run/math.em) for every case below.

## Constants

## Math.pi -> Float

## Math.e -> Float

## Trigonometry

## Math.sin(radians) -> Float

## Math.cos(radians) -> Float

## Math.tan(radians) -> Float

## Math.arc_sin(value) -> Float

## Math.arc_cos(value) -> Float

## Math.arc_tan(value) -> Float

The inverse trigonometric functions return radians and produce `NaN` for an argument outside
their real domain — `arc_sin`/`arc_cos` outside `-1..1`.

## Math.arc_tan2(y, x) -> Float

The two-argument arctangent, taking `y` before `x` so the pair matches the coordinate it
describes; unlike the single-argument form, it uses both values' signs to place the result
in the correct quadrant.

## Logarithms and powers

## Math.natural_log(value) -> Float

## Math.log10(value) -> Float

## Math.log(value, base) -> Float

Natural, base-10, and arbitrary-base logarithms. A negative `value`, or a `base` that is
zero, negative, or `1` (no exponent of `1` reaches another value), produces `NaN`;
`natural_log(0)` produces `-Infinity`.

## Math.power(base, exponent) -> Float

Raises `base` to `exponent`, both as `Float`. A negative `base` raised to a non-integral
`exponent` produces `NaN`. The language operator `**` (5.3) remains the ordinary way to
write a power expression when both operands are already known statically; `Math.power` is
for a base or exponent computed as a value.
