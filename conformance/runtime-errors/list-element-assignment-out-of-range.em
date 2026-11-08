# Section 5.4: assigning into a list past its end is an error at the index,
# not a way to grow the list.

var scores = [90, 85]
scores[2] = 70
