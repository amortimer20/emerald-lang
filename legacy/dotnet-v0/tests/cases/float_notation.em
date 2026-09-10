## Exponent literals, and the rule that anything printed is something that could have
## been typed — which already held for nothing, true and Suit.HEARTS, and did not hold
## for a Float. It printed 1E-07, with an uppercase E that was never Emerald syntax.
var tiny = 1.5e-3
var huge = 1e308
print(tiny)
print(huge)

## A number written this way is a Float whatever its exponent does: 1e3 is 1000.0, not
## 1000. The notation is about magnitude, and Emerald does not pick a type from size.
print(1e3)

## Ordinary numbers are untouched.
print(0.5)
print(4.0)
print(0.0)
print(0.0001)
print(0.1 + 0.2)

## The switch happens where a decimal stops being readable. Past 2^53 a Float no longer
## holds every whole number, so 1e16 is the first round power of ten where printing all
## the digits would claim a precision it does not have.
print(1e16)
print(0.00001)
print(1.2345e-5)
print(0.0 - 1e21)

## Which closes the round trip: each of these was printed by the line above it.
print(1.0e16 == 1e16)
print(1.0e-7 == 0.0000001)
print(1.2345e-5 == 0.000012345)
print(-1.0e21 == 0.0 - 1e21)

## And a Float is shown at whatever length reads back as itself. This one used to print
## as 9007199254740990.0 — the whole-number branch formatted to fifteen significant
## digits, which is not enough, so a value typed exactly came back wrong.
print(9007199254740992.0)
