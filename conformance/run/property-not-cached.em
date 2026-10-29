# Section 10.3: a read-only computed property runs on every read and is not cached;
# compound assignment runs the getter once and the setter once.
struct Circle {
    var radius: Float

    const area: Float {
        print("computing area")
        return self.radius * self.radius * 3.0
    }

    var diameter: Float {
        get {
            print("get diameter")
            return self.radius * 2
        }
        set {
            print("set diameter to #{value}")
            self.radius = value / 2
        }
    }
}

var circle = Circle(radius: 1.0)
print(circle.area)
circle.radius = 2.0
print(circle.area)
circle.diameter += 2
print(circle.radius)
