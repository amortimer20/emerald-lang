# Section 5.2 comparison and word operators, and section 4.4's rule that a mixed
# comparison compares mathematical values rather than widening the integer first.

print(1 < 2, 2 <= 2, 3 > 4, 4 >= 4, 5 == 5, 5 != 5)

# A chain reads as the conjunction of its links.
print(0 <= 14 <= 100)
print(0 <= 500 <= 100)

# Short-circuiting: reaching the divide would raise, so a plain `false` proves
# the chain stopped at the first false link.
print(2 < 1 < 1 // 0)
print(false and 1 // 0 == 0)
print(true or 1 // 0 == 0)

print(not true, not (1 > 2))

# 9007199254740993 is 2^53 + 1, which no Float can represent. Widening it would
# round it onto the value beside it and make these compare equal.
print(9007199254740993 == 9007199254740992.0)
print(9007199254740993 > 9007199254740992.0)
print(2 == 2.0)
