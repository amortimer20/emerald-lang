trait Shape {
    func area(): Float
}
struct Square implements Shape {
    var side: Float
    @override
    func area(): Float {
        return self.side * self.side
    }
}
