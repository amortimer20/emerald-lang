# Mistake: or() fallback of the wrong type (line 3). Source: guide docs/language/types-and-optionals.md.
var n = "5".to_int_maybe()
print(n.or("none") + 1)
