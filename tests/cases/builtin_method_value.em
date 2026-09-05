## A built-in method is a value like any other method (§3.1). It was the one kind that
## was not, which made the rule true everywhere except on the types used most.
func apply(f: func(): String): String { return f() }
func how_many(f: func(): Int): Int { return f() }

var word = "seven"
print(apply(word.upper))
print(apply(word.reverse))
print(how_many(word.count))

var xs = [3, 1, 2]
print(how_many(xs.count))

var sorted: func(): List<Int> = xs.sort
print(sorted().join(", "))

var ages = ["ada": 36, "bo": 7]
var names: func(): List<String> = ages.keys
print(names().join(", "))

## The receiver goes with it, so two of them stay apart.
var short = "hi"
print(apply(word.upper))
print(apply(short.upper))

## And one that takes an argument keeps it.
func holds?(f: func(Int): Bool): Bool { return f(2) }
print(holds?(xs.contains?))
