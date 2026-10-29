# Finding 02: Float % with a negative divisor gives a remainder with the dividend's sign.
# Expected (5.3: a nonzero remainder has the divisor's sign; a == (a // b) * b + a % b):
#   -1.0 -0.5 -1.0 -2.0
print(7.0 % -2.0, 7.5 % -2.0, 5.0 % -3.0, 0.5 % -2.5)
print((7.0 // -2.0) * -2.0 + 7.0 % -2.0)   # expected 7.0
