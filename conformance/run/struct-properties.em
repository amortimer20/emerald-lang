# Section 10.3: a property looks like a field and runs code instead.
struct Circle {
    var radius: Float

    # Read-only: a `const` property's braces are its getter.
    const area: Float {
        return 3.0 * self.radius * self.radius
    }

    # Writable: `set` receives the new value as `value`.
    var diameter: Float {
        get {
            return self.radius * 2
        }
        set {
            self.radius = value / 2
        }
    }

    # A method that sets a property changes `self`.
    func grow() {
        self.diameter += 2
    }
}

var circle = Circle(1)
print(circle.area, circle.diameter)
circle.diameter = 10
print(circle)

# A compound assignment runs the getter once and the setter once.
circle.diameter += 4
print(circle.radius)
circle.grow()
print(circle.radius)

# Reading a property never changes the value, so a `const` may.
const fixed = Circle(2)
print(fixed.area, fixed.diameter)

# A property is reached through indices like a field, and stores nothing, so
# it is neither displayed nor compared.
var circles = [Circle(1), Circle(3)]
circles[1].diameter = 1
print(circles, Circle(2) == fixed)

# A constructor may use properties once every field is set.
struct Square {
    var side: Int

    constructor(area: Int) {
        self.side = 1
        while self.area < area {
            self.side += 1
        }
    }

    const area: Int {
        return self.side * self.side
    }
}
print(Square(10))
