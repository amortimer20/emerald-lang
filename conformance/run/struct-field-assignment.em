struct Point {
    var x: Float
    var y: Int
}

struct Line {
    var start: Point
    var end: Point
}

struct Bag {
    var values: [Int]
}

struct Wrapper {
    var inner: Point
}

struct Counter {
    var value: Int
}

# Plain and compound assignment, and widening an Int into a Float field.
var p = Point(1.0, 2)
p.x = 5.0
print(p)
p.y += 3
print(p)
p.x = 9
print(p)

# A nested field path.
var line = Line(Point(0.0, 0), Point(1.0, 1))
line.start.x = 9.5
print(line)

# An index step followed by a field step.
var points = [Point(0.0, 0), Point(1.0, 1)]
points[0].x = 42.0
print(points)

# A field step followed by an index step.
var bag = Bag([1, 2, 3])
bag.values[0] = 99
print(bag.values)

# A field step through a dictionary lookup, then compound assignment.
var lookup: [String: Point] = ["a": Point(1.0, 1)]
lookup["a"].x += 1
print(lookup["a"].or(Point(0.0, 0)))

# Value semantics: changing one binding's field never changes another's.
var a = Point(1.0, 1)
var b = a
b.x = 99.0
print(a)
print(b)

# A struct returned from a function is independent of the parameter it copied.
func changed(point: Point): Point {
    var copy = point
    copy.x = -1.0
    return copy
}
var c = Point(2.0, 2)
var d = changed(c)
print(c)
print(d)

# A struct held by a list is unaffected when the original binding changes.
var original = Point(3.0, 3)
var held = [original]
original.x = -5.0
print(held)
print(original)

# Two bindings sharing one struct diverge only once one of them changes.
var w = Wrapper(Point(4.0, 4))
var shared = w.inner
w.inner = shared
shared.x = 100.0
print(w.inner)
print(shared)

# The right side runs before the path is walked, so a nested assignment it
# makes is not lost underneath the outer one.
var counter = Counter(1)
func replace(): Int {
    counter.value = 2
    return 99
}
counter.value = replace()
print(counter)
