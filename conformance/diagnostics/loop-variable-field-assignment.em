struct Point {
    var x: Float
    var y: Int
}

var points = [Point(0.0, 0), Point(1.0, 1)]
for point in points {
    point.x = 0.0
}
