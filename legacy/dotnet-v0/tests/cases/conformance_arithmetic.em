## A conformance vector for the CIL backend, not a feature demonstration.
##
## Everything here is a place where emitted IL could quietly disagree with the
## interpreter: the emitter picks a CIL opcode, the opcode has C#'s semantics, and C#'s
## semantics are not always Emerald's. Each line below is a value the backend has to
## reproduce exactly, and this file is the suite it gets diffed against.

## Floored division and modulo, all four sign combinations. CIL's div and rem truncate
## toward zero, so three of these eight numbers differ from the naive opcode and the
## emitter has to correct for it.
for pair in [Pair(7, 2), Pair(-7, 2), Pair(7, -2), Pair(-7, -2)] {
    var a = pair.first()
    var b = pair.second()
    print("#{a},#{b}  // #{a // b}  % #{a % b}  identity #{(a // b) * b + (a % b) == a}")
}

## Floored division done in integers, not through a double. The interpreter used to
## compute it as Math.Floor((double)a / b), which is correct up to 2^53 and silently wrong
## above it: 9223372036854775807 // 3 came out as 3074457345618258432, off by 170. A
## backend emitting the same shortcut would inherit the same wrong answer.
print(9223372036854775807 // 3)
print(9223372036854775807 % 3)
print(-9223372036854775807 // 3)

## Single slash is always a Float, whatever it divides.
print(7 / 2)
print(-7 / 2)
print(6 / 3)

## Rounding is away from zero, which is NOT what Math.Round does by default -- .NET
## rounds a midpoint to even, so Math.Round(2.5) is 2. An emitter reaching for the
## obvious BCL call would silently change every .5 in every program.
print(2.5.round())
print(3.5.round())
print(-2.5.round())
print(0.5.round())

## Truncation toward zero, which is what to_int means and is not what round means.
print(7.9.to_int())
print(-7.9.to_int())

## The Int boundaries, which are Int64's. Arithmetic uses the checked opcodes, so
## crossing one is an error rather than a wraparound -- see err_int_overflow.
print(9223372036854775807)
print(-9223372036854775807 - 1)

## Float printing. The interpreter formats these itself rather than taking .NET's
## default, so the runtime library has to carry the same formatter -- a whole number
## keeps its .0, and the exponent form is lowercase e with a signless positive exponent.
print(1.0)
print(100.0)
print(0.5)
print(1.0e-7)
print(1.0e20)
print(123456789012345678.0)
print(0.1 + 0.2)
print(1.0 / 3.0)
