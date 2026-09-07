## A conformance vector for the CIL backend: what == means for each kind of value.
##
## The emitter has three plausible things to reach for at every comparison -- reference
## equality, Object.Equals, or the user's own method -- and picking the wrong one is
## invisible until two values that look alike disagree. Emerald's rule is per-kind, so it
## travels with the type rather than with the operator.

## Numbers of one type compare by value. Int against Float is deliberately left out of
## this vector: it is currently incoherent -- 1 <= 1.0 and 1 >= 1.0 are both true while
## 1 == 1.0 is false -- and pinning an answer here would bless the contradiction. See
## known_int_and_float_equality.
print(1 == 1)
print(1.0 == 1.0)

## NaN equals nothing, itself included. .NET's Equals disagrees -- it says two NaNs are
## the same value -- and C#'s == agrees with IEEE. An emitter reaching for Equals makes
## x == x true in the one case where every language says it is false.
var nan = Math.sqrt(-1.0)
print(nan == nan)
print(nan != nan)

## Strings compare by value, not by reference, however they were built.
var built = "ab" + "c"
print(built == "abc")

## nothing is equal only to nothing, and comparing against it never dispatches.
var missing: String? = nothing
print(missing == nothing)
print(missing == "abc")

## A struct compares field by field, all the way down, because its value semantics would
## otherwise stop exactly at the question everyone asks first.
struct Point {
    var x: Int
    var y: Int
}
print(Point(1, 2) == Point(1, 2))
print(Point(1, 2) == Point(1, 3))

## A class keeps identity, since nothing better has been said about it.
class Box {
    var n: Int
    constructor(n: Int) { self.n = n }
}
var b = Box(1)
print(b == b)
print(Box(1) == Box(1))

## Unless it says otherwise, in which case its own method decides -- and every wrapper
## has to reach the same method. See equality_through_wrappers for the full set.
class Money with Equatable {
    var cents: Int
    constructor(cents: Int) { self.cents = cents }
    func equals?(other: Money): Bool { return self.cents == other.cents }
}
print(Money(5) == Money(5))
print([Money(5)].contains?(Money(5)))

## Collections compare elementwise, using whatever rule each element has.
print([1, 2] == [1, 2])
print([Point(1, 2)] == [Point(1, 2)])
print([Box(1)] == [Box(1)])
print(["a": 1] == ["a": 1])
print([1, 2].to_set() == [2, 1].to_set())
