class Point with Addable {
    var x: Int
    constructor(x: Int) { self.x = x }
    func add(other: Point): Point { return Point(self.x + other.x) }
}

var a = Point(1)
print("#{a + 5}")
