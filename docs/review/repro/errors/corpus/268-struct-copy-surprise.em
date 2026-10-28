# Mistake: changing a copied struct expecting the original to change (line 7). Source: guide docs/language/objects-and-traits.md (value semantics).
struct Point {
    var x: Int
}
var a = Point(1)
var b = a
b.x = 5
print(a.x)
