## KNOWN HOLE, and this one is unsound today -- no backend required.
##
## The checker resolves this call to run_it(func(Int): Int), which gives back a String,
## and accepts `var answer: String`. The interpreter resolves the same call by looking at
## the value it is holding, does not discriminate on how many parameters the block takes,
## and calls run_it(func(): Int) instead.
##
## So a variable declared String holds an Int, and prints as one. The failure surfaces
## later, at whatever first treats it as a String -- which is the null-reference
## experience non-nullable types exist to abolish, arriving through the other door.
##
## Root cause is not block arity specifically. The checker and the interpreter each
## reconstruct the overload decision from different information, and the interpreter's
## copy is a hand-written match that has now been found missing Pair, function shapes,
## block arity, and list element types, each time by someone looking rather than by a
## test failing. One decision, recorded by the checker and used by the interpreter, is
## the fix that ends the category.

func run_it(g: func(): Int): Int { return 1 }
func run_it(g: func(Int): Int): String { return "one arg" }

var answer: String = run_it({ n => n + 1 })
print(answer)
print(answer.upper())
