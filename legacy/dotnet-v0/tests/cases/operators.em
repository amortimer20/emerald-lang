# Python-style division and exponent

print(7 / 2)          # 3.5   — / always gives a Float
print(7 // 2)         # 3     — // floors
print(-7 // 2)        # -4    — floors toward negative infinity, not toward zero
print(7 % 2)          # 1
print(-7 % 2)         # 1     — matches //, so n % 2 is never negative
print(7.0 // 2.0)     # 3.0

print(2 ** 10)        # 1024  — Int in, Int out
print(2 ** 3 ** 2)    # 512   — right-associative: 2 ** 9
print(-2 ** 2)        # -4    — ** binds tighter than unary minus
print(2 ** -1)        # 0.5   — a negative exponent gives a Float
print(2.0 ** 0.5)     # 1.414...
