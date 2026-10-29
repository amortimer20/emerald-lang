# Mistake: implements keyword (line 5). Source: carry-over from Java/C.
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
