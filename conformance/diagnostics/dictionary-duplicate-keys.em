# Section 8.4: a dictionary literal repeating a key whose value is known
# before the program runs is an error, the same way `case`/`when` treats a
# repeated alternative. Numbers compare by value, so an Int and an equal
# Float repeat each other, and an enum value repeats itself the same way a
# literal does. A key computed at runtime is unrelated: the checker cannot
# see it coming, so it collides silently and the later value wins (8.4).

var by_name: Dict[String, Int] = ["Ava": 1, "Noah": 2, "Ava": 3]

var by_number: Dict[Float, String] = [1: "one", 2: "two", 1.0: "also one"]

enum Color {
    red
    green
}
var by_color: Dict[Color, String] = [Color.red: "r", Color.green: "g", Color.red: "also r"]

func label(n: Int): String {
    return "k#{n}"
}
var computed: Dict[String, Int] = [label(1): 1, label(1): 2]
print(computed)
