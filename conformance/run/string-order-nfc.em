# Section 9.2: ordering compares the NFC code points of both strings, so U+00E9 and its
# decomposed spelling are equal and both sort after "f".
print("\u{e9}" < "f", "e\u{301}" < "f", "\u{e9}" == "e\u{301}")
print(["f", "\u{e9}", "e"].sort())
