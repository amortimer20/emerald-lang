# Integer arithmetic with the precedence from section 5.3.
#
# `var` and named bindings arrive with the statement slice; until then a program
# is a sequence of calls.

print(2 + 3 * 4)
print((2 + 3) * 4)
print(2 ** 3 ** 2)
print(-2 ** 2)
print(7 // 2, 7 % 2, 7 / 2)
