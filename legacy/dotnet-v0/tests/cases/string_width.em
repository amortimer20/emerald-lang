# Width, which the language had no way to ask for at all. A board, a table or a menu had
# nowhere to start, so every project wrote these for itself - and a hand-written pad that
# measures the .NET way lines an accented column up wrong, which is the bug reverse had.

print("[" + "ab".pad_right(6) + "]")
print("[" + "ab".pad_left(6) + "]")
print("[" + "ab".pad_center(6) + "]")

# An odd space goes right, so a column of centered text keeps its left edge straight.
print("[" + "abc".pad_center(6) + "]")

# The fill is optional, and repeats when it is more than one character.
print("[" + "ab".pad_right(6, ".") + "]")
print("[" + "Chapter".pad_right(14, ". ") + "1]")

# Already wide enough is left alone.
print("[" + "toolong".pad_left(3) + "]")

print("-".repeat(20))
print("ab".repeat(3))
print("[" + "ab".repeat(0) + "]")

# Counted in graphemes, so these two line up.
var accented = "héllo"
print(accented.count())
print(accented.pad_right(8, ".") == accented + "...")
print("👋".pad_left(4, "-").count())

# Whole-string questions: is every character one of these.
print("#{"a".letter?()} #{"abc".letter?()} #{"é".letter?()} #{"a1".letter?()} #{"".letter?()}")
print("#{"7".digit?()} #{"42".digit?()} #{"4a".digit?()} #{"".digit?()}")

# blank? is the exception: it asks whether there is nothing here to read, and an empty
# string is the clearest case of that.
print("#{" ".blank?()} #{"".blank?()} #{"a".blank?()}")
