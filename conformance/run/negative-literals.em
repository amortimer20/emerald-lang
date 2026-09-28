# Section 5.3: a `-` written directly against a number is part of the number,
# so a method call applies to the negative number.
print(-3.positive?(), -3.abs(), -2.5.abs(), -2.5.round())
print(-7.to_string(base: 2), -1_000.abs(), -1e3.abs())
print(-9223372036854775808.digits().count)

# The exception: a number that `**` follows keeps its sign apart, so `-2 ** 2`
# is `-(2 ** 2)`, as in mathematics.
print(-2 ** 2, (-2) ** 2, -2.abs() ** 2)

# A `-` with a space after it, or before anything other than a number, negates
# everything that follows it.
const x = 3
print(-x.abs(), - 3.abs(), -(3.abs()))

# A `-` after a value is still subtraction, with or without spaces.
print(x -3, x - 3, 10 - -3.abs())
