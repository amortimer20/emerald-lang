# Mistake: arithmetic on a dictionary lookup (line 3). Source: review brief list (method on an optional); guide docs/language/collections-and-ranges.md.
var ages = ["Ava": 12]
var next_year = ages["Ava"] + 1
print(next_year)
