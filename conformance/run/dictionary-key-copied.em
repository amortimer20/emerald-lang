# Section 8.3: stored value-type keys are copied, so later mutation of the original
# cannot invalidate lookup.
struct Point {
    var x: Int
    var y: Int
}

var corner = Point(x: 1, y: 2)
var labels: Dict[Point, String] = [corner: "start"]
corner.x = 9
print(labels[Point(x: 1, y: 2)].or("missing"))
print(labels[corner].or("missing"))
var seen: Set[Point] = [corner]
corner.y = 7
print(seen.contains?(Point(x: 9, y: 2)), seen.contains?(corner))
