# Section 7.2: a constructor that builds another of its own type names the
# constructor in prose in the trace, with repeated frames summarized. The chain
# stops at a fixed depth and raises its own error, so the case does not depend
# on the call limit.
class Chain {
    var next: Chain? = nothing

    constructor(depth: Int) {
        if depth == 0 {
            raise Error("the chain is long enough")
        }
        self.next = Chain(depth - 1)
    }
}

const chain = Chain(40)
