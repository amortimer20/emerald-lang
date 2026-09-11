# Section 9.4's strict conversion raises for text that is not a number.
# `to_int_or` gives a fallback instead.

var typed = "twelve"
print(typed.to_int_or(0))
print(typed.to_int())
