## KNOWN HOLE, and the one that shows why a local rule is not enough on its own.
##
## Shape's constructor is impeccable by every local measure: it assigns every field Shape
## declares, it calls no method on self, and it reads nothing early. All it does is hand
## self to a different object. That object then calls describe, which dispatches to
## Circle's override, which reads a field Circle's constructor has not reached yet --
## super(into) is still running.
##
## So banning overridable calls on self inside a constructor would not catch this. The
## call that goes wrong is not in any constructor. The escape is the vector, and a base
## constructor cannot establish that the whole object is built, only its own part.
##
## Emerald has no sealed or final, so every class is open and every constructor is
## potentially a base constructor.

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
