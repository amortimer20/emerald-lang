# Inheritance

## A class can extend one other class. `@abstract` says this one only exists to
## be extended, and that `area` is left for each subclass to supply.
@abstract
class Shape {
    const name: String

    constructor(name: String) {
        self.name = name
    }

    @abstract
    func area(): Float

    func describe(): String {
        return "#{self.name} covering #{self.area()}"
    }
}

## A subclass builds its base class's part first, with `super(...)`, and marks
## every method it replaces with `@override`.
class Rectangle extends Shape {
    const width: Float
    const height: Float

    constructor(width: Float, height: Float) {
        super("rectangle")
        self.width = width
        self.height = height
    }

    @override
    func area(): Float {
        return self.width * self.height
    }
}

## `super.describe()` runs the base class's version from inside the new one.
class Square extends Rectangle {
    constructor(side: Float) {
        super(side, side)
    }

    @override
    func describe(): String {
        return "a square: " + super.describe()
    }
}

## A list of shapes can hold any of them, and each runs its own version.
const shapes: [Shape] = [Rectangle(2, 3), Square(4)]
for shape in shapes {
    print(shape.describe())
}

## `is` asks what an object really is. Inside the branch where it holds, the
## shape is known to be a rectangle, so its width can be read.
for shape in shapes {
    if shape is Rectangle {
        print(shape.type_name, "is", shape.width, "wide")
    }
}
