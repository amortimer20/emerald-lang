## The guard returns before the assignment, and a returned object still gets looked at.
class Tag {
    var name: String

    constructor(ok?: Bool) {
        return unless ok?
        self.name = "set"
    }
}

print("never runs")
