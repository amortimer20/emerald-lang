## The same mistake one level up: a static belongs to the type, not to self.
class Circle {
    static const PI = 3.14159

    var radius: Float

    constructor(radius: Float) { self.radius = radius }

    func area(): Float { return PI * self.radius * self.radius }
}
