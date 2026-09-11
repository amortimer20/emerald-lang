# Section 5.3 checks overflow against the 64-bit range settled in 4.2, and
# raises rather than wrapping.

print(9223372036854775807 + 1)
