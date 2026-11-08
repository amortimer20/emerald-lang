# Section 5.3 lowers `+=` on an element through the same read the element
# would get, so an index past the end fails at the index.

var scores = [90, 85]
scores[-1] += 5
