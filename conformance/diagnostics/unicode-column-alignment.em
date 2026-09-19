# Section 3.1's column is a Unicode scalar count, not a byte count: `café`
# is four scalars but five UTF-8 bytes, so a byte-based column would point
# one character early at `oops` below.
var café = 1
print(café, oops)
