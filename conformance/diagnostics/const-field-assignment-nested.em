struct Point {
    var x: Float
    var y: Int
}

struct Line {
    const start: Point
    var end: Point
}

var line = Line(Point(0.0, 0), Point(1.0, 1))
line.start.x = 1.0
