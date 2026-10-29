# Mistake: calling a method on an optional (line 4). Source: review brief list; guide docs/language/types-and-optionals.md.
var names = ["ava", "bo"]
var first = names.first
print(first.upper())
