## One arm assigns and the other does not. Paired with initialization_across_branches,
## which has the same shape with both arms assigning.
class MissingElse {
    var n: Int
    constructor(flag: Bool) {
        if flag { self.n = 1 }
    }
}
