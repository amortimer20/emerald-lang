## The one place membership and == disagree, reaching one level down.
##
## A NaN is equal to nothing, itself included, so == says two of these differ. A hash
## table cannot hold a value that is not equal to itself without losing it, so membership
## compares the fields reflexively and the struct can be stored and found again. That is
## the rule a bare NaN already follows -- a set holds one, not two -- applied at every
## depth rather than only at the top.
struct Reading {
    var value: Float
}

var bad = Reading(Math.sqrt(-1.0))

print(bad == bad)

var seen = [bad, Reading(Math.sqrt(-1.0))].to_set()
print(seen.count())
print(seen.contains?(Reading(Math.sqrt(-1.0))))
