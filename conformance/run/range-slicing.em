# Section 5.4: exclusive/inclusive bounds, omitted bounds, independent Lists,
# and grapheme-aware String boundaries.
var values = [0, 1, 2, 3, 4]
var middle = values[1..<4]
middle[0] = 9
print(middle, values)
print(values[1..3])
print(values[..<2], values[..1])
print(values[3..<], values[3..])
print(values[5..<])

const text = "e\u{301}llo 👋"
print(text[0..<1], text[1..4], text[5..<])
