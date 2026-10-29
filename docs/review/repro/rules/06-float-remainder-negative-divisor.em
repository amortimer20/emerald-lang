# Section 5.3: `%` uses the floor-division law a == (a // b) * b + (a % b), and a
# nonzero remainder has the divisor's sign. Expected -1 / -0.5 / -1.0 on every line.
print(7 % -2)
print(7.5 % -2)
print(7.0 % -2.0)
print(7 % -2.0)
print((7.5 // -2) * -2 + (7.5 % -2))
