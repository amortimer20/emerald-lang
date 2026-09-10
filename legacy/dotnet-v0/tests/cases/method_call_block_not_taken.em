## A method that takes no arguments cannot be handed a block. This used to reach the
## interpreter and fail there.
class Box {
    var n: Int
    constructor(n: Int) { self.n = n }
    func show(): Int { return self.n }
}

Box(1).show { x => x }
