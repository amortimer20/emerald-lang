# static members and properties

class Circle {
    static const PI = 3.14159
    static var made: Int = 0

    var radius: Float

    # A property is a var with a body — callers cannot tell it from a stored field.
    var area: Float {
        get { return Circle.PI * self.radius * self.radius }
    }

    var diameter: Float {
        get { return self.radius * 2.0 }
        set { self.radius = value / 2.0 }
    }

    constructor(radius: Float) {
        self.radius = radius
        Circle.made += 1
    }

    static func unit(): Circle {
        return Circle(1.0)
    }
}

var c = Circle(2.0)
print("radius   #{c.radius}")
print("area     #{c.area}")
print("diameter #{c.diameter}")

c.diameter = 10.0
print("after setting diameter to 10: radius is #{c.radius}")

var u = Circle.unit()
print("unit area #{u.area}")
print("circles made: #{Circle.made}")
