## Why the escape has to be banned outright rather than permitted once the fields are set.
##
## Shape's constructor is impeccable by every local measure: it assigns every field Shape
## declares, calls no method on self, and reads nothing early. All it does is hand self to
## another object -- which calls describe, which dispatches to Circle's override, which
## reads a field super(into) has not reached.
##
## So the call that goes wrong is in no constructor, and a rule about calls would not see
## it. The escape is the vector, and a base constructor can never establish that the whole
## object is built -- only its own part of it.

class Registry {
    var log: List<String> = []

    func record(s: Shape) { self.log.add(s.describe()) }
}

class Shape {
    var kind: String

    constructor(into: Registry) {
        self.kind = "shape"
        into.record(self)
    }

    func describe(): String { return "a #{self.kind}" }
}

class Circle extends Shape {
    var radius: Int

    constructor(into: Registry) {
        super(into)
        self.radius = 3
    }

    override func describe(): String { return "circle of #{self.radius * 2}" }
}

var r = Registry()
Circle(r)
print(r.log.first())
