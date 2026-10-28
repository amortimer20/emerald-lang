## A rectangle, measured by its width and height.
struct Rectangle with Geometry.Shapes.Shape {
    const width: Float
    const height: Float

    @override
    func area(): Float {
        return self.width * self.height
    }

    @override
    func name(): String {
        return "rectangle"
    }
}
