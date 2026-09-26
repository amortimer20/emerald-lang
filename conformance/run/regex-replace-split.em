# Section 15.4's replacing and splitting.
print(Regex('\s+').replace_all("too    many   spaces", " "))
print(Regex('\d').replace("a1b2c3", "#"), Regex('\d').replace_all("a1b2c3", "#"))

# Replacement text is used as it is written: "$1" is a dollar sign and a one.
print(Regex('(\d+)').replace_all("costs 5", "$1"))

# A block computes each replacement from its match.
print(Regex('\d+').replace_each("3 apples and 12 pears") { found => (found.text.to_int() * 2).to_string() })
print(Regex('\w+').replace_each("hello big world") { found => found.text.upper() })
print(Regex('z').replace_each("no match here") { found => "!" })

# `split` keeps empty pieces, as String.split does.
print(Regex('[,\s]+').split("red, green,blue"))
print(Regex(',').split(",a,,b,"), ",a,,b,".split(","))
print(Regex('x').split(""), Regex('x').split("abc"))

# Matches of nothing: after one, the search moves on a character, and one
# just where the last match ended does not count.
print(Regex('x*').find_all("ab"))
print(Regex('\s*').find_all("a b"))
print(Regex('x*').replace_all("ab", "-"), Regex('').replace_all("héllo", "."))

# A pattern that matches nothing splits between every character, but splits
# nothing off the start or end.
print(Regex('').split("abc"), Regex('x*').split("héllo"), Regex('').split(""))
