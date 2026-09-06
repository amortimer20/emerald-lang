## enum — a closed set of named values, and nothing else (§6's harvested demand was
## alignment, dock, orientation and color, all of which are plain names).
enum Color { RED, GREEN, BLUE }

enum Alignment {
    LEFT,
    CENTER,
    RIGHT
}

var c = Color.RED
print(c)
print(c.name)
print(c == Color.RED)
print(c == Color.BLUE)
print(c != Color.BLUE)

## Typed, which is the whole reason not to pass strings around.
var side: Alignment = Alignment.LEFT
print("aligned #{side.name.lower()}")

## Its values, in declaration order.
for color in Color.values {
    print("  #{color}")
}
print(Color.values.count())

func describe(a: Alignment): String {
    return if a == Alignment.CENTER then "middle" else "edge"
}

print(describe(Alignment.CENTER))
print(describe(Alignment.RIGHT))

## An ordinary value: it goes in lists, dictionaries, and sets.
var picked = [Color.RED, Color.BLUE]
print(picked.count())

var labels: Dictionary<String, Int> = [:]
labels[Color.GREEN.name] = 2
print(labels["GREEN"].or(0))
