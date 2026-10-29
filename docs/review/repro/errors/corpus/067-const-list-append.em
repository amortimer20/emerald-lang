# Mistake: appending to a const list (line 3). Source: guide docs/language/collections-and-ranges.md.
const names = ["Ava"]
names.append("Bo")
print(names)
