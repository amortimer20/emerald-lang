# Mistake: reading a field that does not exist (line 7). Source: Kohn 2019 (The Error Behind the Message, Python novices) (AttributeError).
struct Point {
    var x: Int
    var y: Int
}
var p = Point(1, 2)
print(p.z)
