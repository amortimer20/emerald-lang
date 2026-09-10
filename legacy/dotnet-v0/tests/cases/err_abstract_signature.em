## The same check on an abstract class, since it is the same promise.
class Shape {
    abstract func area(): Int
}

class Square extends Shape {
    func area(): String { return "not a number" }
}
