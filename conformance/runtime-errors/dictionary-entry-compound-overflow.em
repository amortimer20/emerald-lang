# Section 5.3: `+=` on a dictionary entry overflows like any addition, and
# points at the entry it changes.

var totals = ["all": 9223372036854775807]
totals["all"] += 1
