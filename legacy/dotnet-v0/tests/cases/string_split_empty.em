# Splitting on nothing gives every character, and agrees with chars() on what a
# character is -- including one built from several code points.

print("a-b-c".split("-"))
print("abc".split(""))
print("abc".split("") == "abc".chars())
print("".split(""))

var family = "héllo👩‍👩‍👧"
print(family.split("").count())
print(family.split("") == family.chars())
