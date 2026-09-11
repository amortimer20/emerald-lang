# A quote before the closing `}` starts a new string inside the interpolation,
# so what the reader has to fix is the `}`, and that is what is reported.

var count = 3
print("There are #{count gems.")
