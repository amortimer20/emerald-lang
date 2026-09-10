## A property is read, not called. A field and a property are deliberately the same at
## the call site — that interchange is what survived the removal of optional parens.
class Circle {
    var radius: Float
    var area: Float { get { return 3.14 * self.radius * self.radius } }
    constructor(radius: Float) { self.radius = radius }
}

print(Circle(2.0).area())
