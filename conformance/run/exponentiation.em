# Section 5.3: two Ints give an Int, so squares and cubes stay whole numbers.
# A Float on either side gives a Float.

var side = 7
var area: Int = side ** 2
print(area, 2 ** 10, (-2) ** 3)
print(2.0 ** 3, 9 ** 0.5)

# Checked like every other Int operation, and exact at the bottom of the range.
print((-2) ** 63)
