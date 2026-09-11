# Section 4.1 infers a local from its initializer and accepts an explicit type.
# Section 4.4 widens Int to Float, and the widening actually happens: `rate`
# prints as a Float because that is the type it was declared with.

var inferred = 1
var annotated: Int = 2
var rate: Float = 1

print(inferred, annotated, rate)

rate = 3
print(rate)

# Definite assignment proved through both branches of a conditional.
var message: Int

if inferred > 0 {
    message = 10
}
else {
    message = 20
}

print(message)
