struct Point {
    var x: Int
}

struct Holder {
    var maybe: Point?
}

var h = Holder(Point(1))
h.maybe.x = 2
