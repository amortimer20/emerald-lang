# Type-level members reached from another file: through the namespace, or
# directly after `using`.
struct Circle {
    var radius: Float
    var Circle.made = Circle.announce()

    constructor(radius: Float) {
        self.radius = radius
        Circle.made += 1
    }

    func Circle.unit(): Circle {
        return Circle(1)
    }

    func Circle.announce(): Int {
        print("setting up Circle")
        return 0
    }
}

func circles_made(): Int {
    return Circle.made
}
