# split and replace return the receiver's original bytes, not NFC text (9.1, 9.2).

print("cafe\u{301}".split(",")[0].code_points())
print("cafe\u{301}".replace("x", "y").code_points())
print("cafe\u{301} x".split("x")[0].code_points())
print("cafe\u{301} x".replace("x", "y").code_points())
print("a\u{E9}b".split("e\u{301}").map { piece => piece.code_points() })
print("a\u{E9}b".replace("e\u{301}", "-"))
