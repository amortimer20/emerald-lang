# Mistake: constructing an abstract class (line 7). Source: guide docs/language/objects-and-traits.md.
@abstract
class Shape {
    @abstract
    func area(): Float
}
var s = Shape()
