# Section 4.1's definite assignment through loops. `while true` ends only
# through `break`, so what every `break` assigned is known after it.

var found: Int
var candidate = 1
while true {
    candidate += 1
    if candidate * candidate > 50 {
        found = candidate
        break
    }
}
print(found)

# A function may end in a loop that only a `return` leaves.
func first_multiple(factor: Int, above: Int): Int {
    var number = above + 1
    while true {
        return number if number % factor == 0
        number += 1
    }
}
print(first_multiple(7, 20))
