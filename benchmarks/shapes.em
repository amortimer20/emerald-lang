# Classes and methods chosen at run time: an inheritance hierarchy.

class Shape {
    func area(): Float {
        return 0.0
    }
}

class Circle extends Shape {
    const radius: Float

    constructor(radius: Float) {
        self.radius = radius
    }

    @override
    func area(): Float {
        return 3.14159 * self.radius * self.radius
    }
}

class Square extends Shape {
    const side: Float

    constructor(side: Float) {
        self.side = side
    }

    @override
    func area(): Float {
        return self.side * self.side
    }
}

var shapes: List[Shape] = []
for index in 0..<2000 {
    if index.even?() {
        shapes.append(Circle(index.to_float() / 100))
    }
    else {
        shapes.append(Square(index.to_float() / 50))
    }
}
var total = 0.0
for _ in 0..<200 {
    for shape in shapes {
        total += shape.area()
    }
}
print(total.round_to(2))
