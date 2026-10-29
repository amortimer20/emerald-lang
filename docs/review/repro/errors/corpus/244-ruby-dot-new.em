# Mistake: Ruby Point.new (line 6). Source: carry-over from Ruby.
struct Point {
    var x: Int
    var y: Int
}
var p = Point.new(1, 2)
print(p)
