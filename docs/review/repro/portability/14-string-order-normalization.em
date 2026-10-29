# 9.2: ordering compares "normalized code points" without naming the form.
# Under NFC (the interpreter) U+00E9 sorts after "f"; under NFD it is e + U+0301
# and sorts before.
print("\u{e9}" < "f", "e\u{301}" < "f", "\u{e9}" == "e\u{301}")
print(["f", "\u{e9}", "e"].sort())
