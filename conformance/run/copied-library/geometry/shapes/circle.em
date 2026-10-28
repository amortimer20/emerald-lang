## A circle, measured by its radius.
struct Circle with Geometry.Shapes.Shape {
    const radius: Float

    @override
    func area(): Float {
        return Math.pi * self.radius ** 2
    }

    @override
    func name(): String {
        return "circle"
    }
}
