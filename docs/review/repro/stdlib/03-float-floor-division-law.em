# Finding 03: Float // rounds the already-rounded quotient, so // and % break the 5.3 law.
# 0.1 is slightly above one tenth, so 0.5 / 0.1 is just under 5: floor is 4.0.
# Expected: 4.0 0.09999999999999998 0.5   (Python: 0.5 // 0.1 == 4.0)
print(0.5 // 0.1, 0.5 % 0.1, (0.5 // 0.1) * 0.1 + 0.5 % 0.1)
