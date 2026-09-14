# Section 10.2: construction cannot run overridable code through `self`, and `super` reaches methods and properties only.
class Base {
    var count: Int = 0
    var _hidden: Int = 0
    var Base.total = 0

    constructor() {
        self.reset()
        const r = self.reset
        print(self.doubled)
        self.doubled = 4
    }

    func reset() {
        self.count = 0
    }

    var doubled: Int {
        get {
            return self.count * 2
        }
        set {
            self.count = value // 2
        }
    }
}

class Derived extends Base {
    var name: String

    constructor() {
        super()
        super.reset()
        self.name = "d"
        print(super.count)
        super.count = 3
        print(self._hidden)
        super.doubled = "x"
    }
}

class Other {
}

const d = Derived()
const b: Base = d
print(d == b, d == Other())
const back: Derived = b
print(d.total)
