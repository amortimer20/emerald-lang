# The minimum Int has no positive counterpart, so negating it overflows rather
# than wrapping back to itself, as two's-complement hardware would.

const lowest = -9223372036854775808
print(-lowest)
