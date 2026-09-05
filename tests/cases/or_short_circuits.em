## .or is an intrinsic, not a method (§3.2), and its whole meaning is "the value to use
## when there is none" — so the fallback runs only when there is none. It read as a call
## and behaved like one: the fallback ran every time and was discarded, taking whatever
## side effects it had with it.
##
## §3.2 already defined .or(x) as `if v != nothing then v else x`, which evaluates one
## branch, and called it a compiler intrinsic. The behaviour was the thing out of step,
## not the specification.
func fallback(): String {
    print("  ...the fallback ran")
    return "-"
}

var here: String? = "present"
var gone: String? = nothing

print(here.or(fallback()))
print(gone.or(fallback()))

## The shape that made it more than wasted work: side effects for a value already there.
var counts = ["a": 1]
var issued = 0

func next_id(): Int {
    issued += 1
    return issued
}

print(counts["a"].or(next_id()))
print(counts["b"].or(next_id()))
print("ids consumed: #{issued}")

## Everything beside it short-circuits, including the operator it shares a name with.
print(true or fallback().empty?())

var widened: Float? = nothing
print(widened.or(2))
