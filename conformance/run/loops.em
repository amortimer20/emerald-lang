# Section 6.4: `while`, `for` over a range, `break`, and `continue`.

var total = 0
for number in 1..5 {
    total += number
}
print(total)

# `..<` excludes the end.
for index in 0..<3 {
    print(index)
}

# Ranges only count upward, so a start past the end visits nothing. This is
# what keeps a computed bound safe: for an empty list, `0..count - 1` is empty.
var count = 0
for index in 0..count - 1 {
    print(index)
}

var remaining = 10
while remaining > 0 {
    remaining -= 3
    continue if remaining > 4
    print(remaining)
}

# `break` and `continue` act on the innermost loop.
for row in 1..3 {
    for column in 1..3 {
        break if column > row
        print(row * 10 + column)
    }
}

# A range may end at the largest Int; stepping past it would overflow.
for largest in 9223372036854775807..9223372036854775807 {
    print(largest)
}
