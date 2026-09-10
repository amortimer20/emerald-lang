## A conformance vector for the CIL backend: when things happen, rather than what they
## answer.
##
## The other vectors pin values. This one pins *order and count* -- which subexpression
## runs first, and which does not run at all. A backend can get every value right and
## still emit control flow that evaluates an operand it should have skipped, or evaluates
## one twice, and no test that only checks the answer would see it. Every line below
## prints as a side effect, so the transcript is the assertion.

func say?(s: String): Bool { print(s)  return true }
func num(s: String, n: Int): Int { print(s)  return n }

## Arguments and operands go left to right, always.
print(num("operand 1", 1) + num("operand 2", 2))

func takes(x: Int, y: Int) { print("took #{x} and #{y}") }
takes(num("argument 1", 1), num("argument 2", 2))

## The receiver is evaluated before the arguments, which is what lets ?. skip the
## arguments of a call it is not going to make.
func list_of(s: String): List<Int> { print(s)  return [1, 2, 3] }
print(list_of("receiver").index_of(num("then the argument", 2)))

## and / or short-circuit. The first two evaluate both sides because the left does not
## settle the answer; the second two must not evaluate the right at all.
print(say?("and: left") and say?("and: right"))
print(false or say?("or: right"))

var no = false
print(no and say?("NEVER: and skips this"))
print(true or say?("NEVER: or skips this"))

## ?. on nothing skips the call, and with it the arguments -- so an expensive argument is
## not paid for a call that does not happen.
var missing: List<Int>? = nothing
print(missing?.index_of(num("NEVER: optional call skips this", 1)))

var present: List<Int>? = [7]
print(present?.index_of(num("optional call does happen", 7)))

## .or is an intrinsic, not a method, and its whole meaning is "the value to use when
## there is none" -- so the fallback is evaluated only when there is none. Written as an
## ordinary call it would run both sides and discard one, burning whatever the fallback
## did on the way.
var here: Int? = 5
print(here.or(num("NEVER: or fallback not needed", 0)))

var gone: Int? = nothing
print(gone.or(num("or fallback is needed", 99)))

## An if expression evaluates one branch, never both.
print(if true then num("chosen branch", 1) else num("NEVER: other branch", 2))

## A condition is evaluated once per turn of the loop, and the body only while it holds.
var i = 0
while i < 2 {
    print("turn #{i}")
    i = i + 1
}
