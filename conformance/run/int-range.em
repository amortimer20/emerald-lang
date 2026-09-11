# Section 4.2's Int range is asymmetric. The minimum's digits alone are one past
# the maximum, so writing it depends on reading the minus and the literal
# together.

print(-9223372036854775808, 9223372036854775807)
print(-9223372036854775808 + 1)
