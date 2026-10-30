# Section 5.3: Float `%` takes the divisor's sign, `//` floors the exact quotient, and the
# two satisfy `a == (a // b) * b + (a % b)`. An infinite remainder operand gives NaN.
print(7.0 % -2.0, 7.5 % -2.0, 5.0 % -3.0, 0.5 % -2.5, -7.0 % 2.0)
print(7.0 // -2.0, 0.5 // 0.1, -0.5 // 0.000001)
print((7.0 // -2.0) * -2.0 + 7.0 % -2.0)
print((0.5 // 0.1) * 0.1 + 0.5 % 0.1)
const infinity = 1e308 * 10
print((5.0 % infinity).nan?(), (5.0 % -infinity).nan?(), (-5.0 % infinity).nan?())

# Section 9.3: `**` and `Math.power` are correctly rounded for large exponents.
print(1.1 ** 1000.0)
print(Math.power(1.005, 123456.789))
print(2.0 ** 10, 10.0 ** 22, (-2.0) ** 3.0, 2.0 ** -1)

# Section 9.3: `round_to` rounds the shortest decimal display, halfway away from zero, and
# leaves a value with no digits at the requested place unchanged.
print(2.675.round_to(2), 1.005.round_to(2), 1.45.round_to(1), (-2.5).round_to(0))
print(2247410860550237.2.round_to(2), 3949998310996723.5.round_to(1))
print(1e300.round_to(5), 1e300.round_to(-300), (-28609247935418.004).round_to(2))
print(1250.0.round_to(-2), 999.9.round_to(-1), 9.96.round_to(1), 40.0.round_to(-2))
