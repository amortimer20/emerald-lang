# Int stays Int through negation, floor division, and integer exponent.
# A Float appears only when one is asked for — which `/` now always does.
print(-7)
print(-7 // 2)
print(7 // 2)
print(7 % 2)
print(-7.5)
print(7 / 2)
print(2 ** 10)
print(Math.min(3, 9))
print(Math.max(3, 9))
print((0 - 7).abs)
