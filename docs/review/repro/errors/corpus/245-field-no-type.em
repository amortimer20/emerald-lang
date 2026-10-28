# Mistake: struct field with no type or value (line 3). Source: carry-over from Python.
struct Point {
    var x
    var y: Int
}
print(Point(1, 2))
