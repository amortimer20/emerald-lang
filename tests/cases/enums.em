## enum — a closed set of named values, and nothing else (§6's harvested demand was
## alignment, dock, orientation and colour, all of which are plain names).
enum Colour { RED, GREEN, BLUE }

enum Alignment {
    LEFT,
    CENTER,
    RIGHT
}

var c = Colour.RED
print(c)
print(c.name)
print(c == Colour.RED)
print(c == Colour.BLUE)
print(c != Colour.BLUE)

## Typed, which is the whole reason not to pass strings around.
var side: Alignment = Alignment.LEFT
print("aligned #{side.name.lower()}")

## Its values, in declaration order.
for colour in Colour.values {
    print("  #{colour}")
}
print(Colour.values.count)

func describe(a: Alignment): String {
    return if a == Alignment.CENTER then "middle" else "edge"
}

print(describe(Alignment.CENTER))
print(describe(Alignment.RIGHT))

## An ordinary value: it goes in lists, dictionaries, and sets.
var picked = [Colour.RED, Colour.BLUE]
print(picked.count)

var labels: Dictionary<String, Int> = [:]
labels[Colour.GREEN.name] = 2
print(labels["GREEN"].or(0))
