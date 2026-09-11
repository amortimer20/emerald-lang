# Section 3.1. A newline ends a statement only after a token that can end an
# expression, and never while a parenthesis or bracket is open. Continuation is
# decided by the preceding tokens, never by indentation or the following line.

var sum = 1 +
    2 +
    3

var numbers = [
    1,
    2,
    3,
]

print(
    sum,
    numbers.count
)

var total = 0

for number in numbers {
    total += number
}
