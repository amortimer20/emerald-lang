# Finding 08: a separator matches inside a grapheme, splitting "e" from its combining accent.
# Expected (9.1 "a character is never split"; 15.11 separator is one grapheme): [["ae\u{301}b"]]
print(Csv.parse("ae\u{301}b", separator: "e")[0].map { field => field.code_points() })
