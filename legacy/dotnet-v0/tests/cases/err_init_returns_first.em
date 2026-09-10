## An early return is an exit, and an exit taken before the assignment leaves the object
## half-built. This is the guard-clause shape from initialization_across_branches with
## its assignment removed.
class ReturnsBeforeAssigning {
    var n: Int
    constructor(flag: Bool) {
        if flag { return }
        self.n = 1
    }
}
