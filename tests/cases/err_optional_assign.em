## A write that may or may not happen is a statement whose effect is not on the page.
class Box {
    var n: Int
    constructor(n: Int) { self.n = n }
}

var b: Box? = Box(1)
b?.n = 5
