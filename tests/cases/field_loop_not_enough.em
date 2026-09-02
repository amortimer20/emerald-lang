## A loop may run zero times, so what it assigns is not guaranteed.
class Tag {
    var name: String

    constructor(n: Int) {
        for i in 1..n { self.name = "set" }
    }
}

print("never runs")
