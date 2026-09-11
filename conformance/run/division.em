# Section 5.3. `/` always produces a Float, `//` rounds toward negative
# infinity, and a nonzero remainder carries the divisor's sign.

print(7 / 2)
print(6 / 3)

print(7 // 2)
print(-7 // 2)
print(7 // -2)
print(-7 // -2)

print(7 % 3)
print(-7 % 3)
print(7 % -3)
print(-7 % -3)

print(7.0 // 2)

# The law that pairs the two: a == (a // b) * b + (a % b)
print(-7 // 3 * 3 + -7 % 3)
print(7 // -3 * -3 + 7 % -3)
