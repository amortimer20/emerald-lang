## Overloads inherit. A subclass declaring one version replaces that version and leaves
## its siblings reachable, which is what C#, Java and Kotlin do.
##
## This file used to assert the opposite -- that a class's own draw replaced the base's
## whole set, C++-style -- and the rule was dropped because it was the odd one out among
## the languages Emerald borrows from, and because it could not survive the boundary: a
## C# caller sees what the CLR inherited either way.
class Shape {
    func draw(): String { return "shape" }

    func draw(times: Int): String { return "shape x#{times}" }
}

class Circle extends Shape {
    override func draw(): String { return "circle" }
}

class Square extends Shape {
    # A version the base does not have is a new overload, and says no override.
    func draw(label: String): String { return "square #{label}" }
}

var c = Circle()
print(c.draw())
print(c.draw(3))

# Through a base reference, the override still wins and the sibling is still there.
var s: Shape = c
print(s.draw())
print(s.draw(2))

var q = Square()
print(q.draw())
print(q.draw(2))
print(q.draw("wide"))
