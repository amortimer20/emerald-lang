# Negative portion counts are likely mistakes, so they say so rather than
# quietly becoming an empty list.
print([1, 2].drop(-1))
