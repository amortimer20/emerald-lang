# A built-in method is found by head type, and a head reads through a ? - so an Int?
# was looked up as an Int and every method on it passed the checker, then failed at
# runtime. The types this hit are the ones most maybes have: to_int_maybe, find, and a
# dictionary lookup nearly all give back a primitive one.

var typed = "banana".to_int_maybe()
print(typed.abs())

var ages = ["ada": 36]
print(ages["nobody"].round_to(1))

var names = ["ada", "grace"]
print(names.find { n => n.count() > 20 }.upper())
