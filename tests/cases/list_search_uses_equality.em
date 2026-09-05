## Searching a list has to mean what == means. It used .NET's idea of sameness, so a type
## that defined equals? got one answer from `a == b` and the opposite from
## `list.contains?(b)` — the same question, asked twice, answered differently.
class Tag with Equatable {
    var name: String

    constructor(name: String) { self.name = name }

    func equals?(other: Tag): Bool { return self.name == other.name }
}

var tags = [Tag("red"), Tag("blue")]

print(Tag("red") == Tag("red"))
print(tags.contains?(Tag("red")))
print(tags.index_of(Tag("blue")))

tags.remove(Tag("red"))
print(tags.count)

## And structs, which now answer for themselves.
struct Point {
    var x: Int
    var y: Int
}

var points = [Point(1, 2), Point(3, 4)]
print(points.contains?(Point(3, 4)))
print(points.index_of(Point(1, 2)))

points.remove(Point(1, 2))
print(points.count)
print(points[0].x)
