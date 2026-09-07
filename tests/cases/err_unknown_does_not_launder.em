## An abstract contract with no return type asks for nothing in particular, which is what
## the operator traits are built on. Reached through a trait-typed reference that used to
## satisfy any declared type, so an Int arrived in a String and failed somewhere else.
trait Giver {
    abstract func give(n)
}

class Counting with Giver {
    func give(n: Int): Int { return n }
}

var g: Giver = Counting()
var text: String = g.give(1)

print(text.upper())
