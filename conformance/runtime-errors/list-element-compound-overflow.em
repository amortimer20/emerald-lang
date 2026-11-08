# Section 5.3 lowers `+=` on a list element through the same addition as
# `a + b`, and an overflow points at the element it changes.

var totals = [9223372036854775807]
totals[0] += 1
