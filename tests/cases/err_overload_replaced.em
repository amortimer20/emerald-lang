## §3.2: a subclass declaring a name replaces the base's whole set for it, which is what
## overriding means. The arity error alone sent the reader to look at Circle for a method
## they could plainly see on Shape, so the diagnostic now says what happened to it.
class Shape {
    func draw(): String { return "shape" }

    func draw(times: Int): String { return "shape x#{times}" }
}

class Circle extends Shape {
    override func draw(): String { return "circle" }
}

print(Circle().draw(3))
