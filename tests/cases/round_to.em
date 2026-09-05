## round gives a whole number; round_to gives a Float. Two names because the answer is
## two types — one name returning either is an overload, which Emerald has not built.
var pi = 3.14159265

print(pi.round())
print(pi.round_to(0))
print(pi.round_to(2))
print(pi.round_to(4))

## Halfway rounds away from zero, the way a maths class does.
print(2.5.round())
print(2.345.round_to(2))
print((0.0 - 2.5).round())

var whole: Int = pi.round()
var part: Float = pi.round_to(2)
print("#{whole} and #{part}")
