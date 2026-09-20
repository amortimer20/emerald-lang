# Section 15.1's `Textual`: a type that adopts the prelude trait displays
# through its own `to_string()` in `print`, `write`, and interpolation.

struct Point with Textual {
    const x: Int
    const y: Int

    @override
    func to_string(): String {
        return "(#{self.x}, #{self.y})"
    }
}

const point = Point(1, 2)
print(point)
print("the point is #{point}")
print(point.to_string())

# The rendering replaces the value's own form wherever it appears, and never
# how a container frames it: an adopting value is not quoted the way a String
# nested in a collection is.
print([point, Point(3, 4)])
print(("left", point))
print(["origin": point])
print([point].to_set())

# A plain struct keeps its field-based form, and an adopting value nested in
# one still renders through the trait.
struct Box {
    const item: Point
}
print(Box(point))

# Section 12: an enum adopting the trait uses it in place of its qualified
# name, and one that does not keeps the qualified name.
enum Suit with Textual {
    hearts, spades

    @override
    func to_string(): String {
        return case self {
            when Suit.hearts then "H"
            when Suit.spades then "S"
        }
    }
}

enum Plain {
    first, second
}
print(Suit.hearts, [Suit.spades], Plain.first)

# Section 10.7: the version the value's own class runs wins, so a subclass's
# override renders even through a list typed as the base class.
class Animal with Textual {
    const name: String

    constructor(name: String) {
        self.name = name
    }

    @override
    func to_string(): String {
        return "animal #{self.name}"
    }
}

class Dog extends Animal {
    constructor(name: String) {
        super(name)
    }

    @override
    func to_string(): String {
        return "dog #{self.name}"
    }
}

const pets: List[Animal] = [Animal("generic"), Dog("Rex")]
print(pets)

# A trait that builds on `Textual` carries the adoption with it.
trait Pretty with Textual {
    func label(): String
}

struct Tag with Pretty {
    const name: String

    @override
    func to_string(): String {
        return "#" + self.name
    }

    @override
    func label(): String {
        return self.name
    }
}
print(Tag("zig"), Tag("em").label())

# A `to_string()` that raises propagates like any other call, and nothing of
# the line it interrupted reaches the output.
struct Unrenderable with Textual {
    const reason: String

    @override
    func to_string(): String {
        raise RuntimeError(self.reason)
    }
}

try {
    print("never written", Unrenderable("cannot render"))
}
catch error: RuntimeError {
    print("caught #{error.message}")
}

try {
    print([Unrenderable("nested")])
}
catch error: RuntimeError {
    print("caught #{error.message}")
}

# An object that reaches itself shows `Name(...)` at the repeat rather than
# running forever, the same guard the field-based form uses.
class Node with Textual {
    var next: Node?

    constructor() {
        self.next = nothing
    }

    @override
    func to_string(): String {
        return "node -> #{self.next}"
    }
}

var loop = Node()
loop.next = loop
print(loop)
