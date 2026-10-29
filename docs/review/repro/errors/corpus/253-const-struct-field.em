# Mistake: changing a field of a const struct (line 7). Source: guide docs/language/objects-and-traits.md.
struct Point {
    var x: Int
    var y: Int
}
const p = Point(1, 2)
p.x = 5
