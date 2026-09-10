## A conformance vector for the CIL backend: the boundaries of Int.
##
## Emerald's integer arithmetic uses the checked opcodes -- add.ovf, sub.ovf, mul.ovf --
## so crossing a boundary is an error rather than a wraparound. The unchecked forms are
## what a C# emitter reaches for by default, and the difference is invisible until a
## program is one operation past the edge: 9223372036854775807 + 1 either reports, or
## silently becomes the most negative number there is.

## The edges themselves are ordinary values.
print(9223372036854775807)
print(-9223372036854775807 - 1)

## Arithmetic that stays inside is ordinary too.
print(9223372036854775806 + 1)
print(-9223372036854775807 - 1 + 1)
print(4611686018427387903 * 2)

## Float has no such boundary -- it saturates to infinity rather than reporting, which
## is IEEE's rule and not something the language overrides.
print(1.0e308 * 10.0)
print(-1.0e308 * 10.0)

## Conversions at the edge. to_int truncates toward zero and does not round.
print(9223372036854775807.to_string().count())
print((-1.9).to_int())
print(1.9.to_int())
