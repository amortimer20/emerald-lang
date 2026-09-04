## A literal mixing values with nothing. List<String?> was always a real type and the
## runtime always handled it — but the literal inferred its element type item by item
## with no rule for nothing, so `["ada", nothing]` was refused and the only way to build
## one was an empty list and .add for every item.
var names: List<String?> = ["ada", nothing, "bo"]

print(names.count)
for name in names {
    print(name.or("(none)"))
}

## Inferred without an annotation, too.
var guesses = ["red", nothing]
print(guesses[0].or("-"))
print(guesses[1].or("-"))

## And for a class, and for a dictionary's values.
class Box {
    var n: Int
    constructor(n: Int) { self.n = n }
}

var boxes: List<Box?> = [Box(1), nothing]
print(boxes[0].or(Box(0)).n)
print(boxes[1].or(Box(0)).n)

var scores = ["ada": 1, "bo": nothing]
print(scores["ada"].or(0))
print(scores["bo"].or(0))
