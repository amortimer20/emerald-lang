## A struct holding a struct is still a key: every field is one, so the hash reaches all
## the way down the same way == does.
struct Point {
    var x: Int
    var y: Int
}

struct Line {
    var from: Point
    var to: Point
}

var lengths: Dictionary<Line, Int> = [:]
lengths.set(Line(Point(0, 0), Point(0, 5)), 5)
print(lengths[Line(Point(0, 0), Point(0, 5))])
