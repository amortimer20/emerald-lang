## A conformance vector for the CIL backend: what a lambda captures, and how long it
## lives.
##
## Emitted code turns a closure into a class with fields, and every decision about which
## variable becomes which field is a place the answer can change. C# got the most famous
## one wrong for five versions -- a lambda in a `for` loop captured the single shared
## variable, so every lambda saw the final value -- and fixed it for `foreach` in C# 5 as
## a breaking change. That is the exact shape of mistake an emitter makes by accident.

## A loop variable is captured per turn, not shared. This must print 1 2 3, never 3 3 3.
var fns: List<func(): Int> = []
for i in 1..3 { fns.add({ i }) }
for f in fns { print(f()) }

## Capture is by reference, not by value: the lambda sees later writes, and its own
## writes are visible outside. A field-per-capture emitter gets this right; one that
## copies the value at creation does not.
var n = 0
var bump: func() = { n = n + 1 }
bump()
bump()
print(n)

## A captured local outlives the call that created it, which is what forces it into a
## heap object rather than a stack slot.
func counter(): func(): Int {
    var c = 0
    return {
        c = c + 1
        return c
    }
}

var next = counter()
print(next())
print(next())

## And each call gets its own, so two counters do not share a field.
var other = counter()
print(other())
print(next())

## A block lambda's returns are typed by what the receiving position asks for. This used
## to be Unknown, which after unknowns stopped satisfying declared types meant a lambda
## plainly handing back an Int was rejected as a func() giving nothing.
var doubled: func(Int): Int = {
    n2 =>
    var twice = n2 * 2
    return twice
}
print(doubled(21))
