# Section 9.4. A whole Float keeps the marker identifying it, signed zero
# survives, and scientific notation applies below 1e-6 or at least 1e16 with the
# boundary values themselves falling on either side.

print(4.0 / 2)
print(1.0 / 3)
print(-0.0)

print(1e15)
print(1e16)
print(1e-6)
print(1e-7)

print(1e308 * 10)
print(-(1e308 * 10))
print(1e308 * 10 - 1e308 * 10)
