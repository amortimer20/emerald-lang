# Section 8.6: `range.map` returns a completed list, and `take`/`drop` on a range
# return a list too.
const squares = (1..4).map { number => number * number }
print(squares, squares.type_name)
const first = (1..10).take(3)
print(first, first.type_name)
const rest = (1..5).drop(3)
print(rest, rest.type_name)
