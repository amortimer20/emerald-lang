# Mistake: arithmetic on to_int_maybe() (line 4). Source: review brief list (method on an optional); guide docs/language/types-and-optionals.md.
var text = "41"
var n = text.to_int_maybe()
print(n + 1)
