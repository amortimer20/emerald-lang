# Section 9.3's global and repeatable randomness services.
print(random(7..7))
print(["only"].random())
print([1].shuffle())

var values = [1, 2, 3, 4]
values.shuffle!()
print(values.sort())

const first = Random(seed: 42)
const second = Random(seed: 42)
print(first.next(1..100) == second.next(1..100))
print(first.choose(["a", "b", "c"]) == second.choose(["a", "b", "c"]))

var left = [1, 2, 3, 4, 5]
var right = [1, 2, 3, 4, 5]
first.shuffle!(left)
second.shuffle!(right)
print(left == right)
