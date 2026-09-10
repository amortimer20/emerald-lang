## A loop body is not a path that always runs. A range that happens to be non-empty here
## does not make the field assigned -- the rule is about the shape, not about arithmetic
## the checker would have to evaluate.
class OnlyInALoop {
    var n: Int
    constructor() {
        for i in 0..3 { self.n = i }
    }
}
