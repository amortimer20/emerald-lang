# An Int has no fraction to hold 2 ** -1, so a negative Int exponent raises and
# points at the Float spelling instead of quietly changing the result type.

var exponent = -1
print(2 ** exponent)
