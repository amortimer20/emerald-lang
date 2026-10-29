# Finding 04: split and replace return NFC text instead of the receiver's original bytes.
# Expected (9.2: "A String retains exactly the bytes it was built from"):
#   [99, 97, 102, 101, 769]   for both lines (a decomposed e + U+0301 is kept)
print("cafe\u{301}".split(",")[0].code_points())
print("cafe\u{301}".replace("x", "y").code_points())
