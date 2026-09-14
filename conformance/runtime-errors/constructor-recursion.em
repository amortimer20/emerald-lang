# Section 7.2: a constructor that builds another of its own type without end
# reaches the call limit, and the error names the constructor in prose.
class Chain {
    var next: Chain? = nothing

    constructor() {
        self.next = Chain()
    }
}

const chain = Chain()
