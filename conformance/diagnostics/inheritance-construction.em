# Section 10.7's abstract classes and section 10.2's construction of a subclass.
@abstract
class Shape {
    const label: String

    constructor(label: String) {
        self.label = label
    }

    @abstract
    func area(): Float

    @abstract
    func perimeter(): Float
}

class Lazy {
    @abstract
    func nothing_here()
}

class Square extends Shape {
    var side: Float = 1

    constructor() {
        super("square")
    }

    @override
    func area(): Float {
        return super.area()
    }
}

const shape = Shape("s")

class Needy extends Shape {
    var extra: Int
}

class NoFields extends Shape {
    @override
    func area(): Float {
        return 1
    }

    @override
    func perimeter(): Float {
        return 1
    }
}

class Forgetful extends Shape {
    constructor() {
        self.label = "x"
    }

    @override
    func area(): Float {
        return 1
    }

    @override
    func perimeter(): Float {
        return 1
    }
}

class Late extends Shape {
    var side: Float

    constructor() {
        self.side = 2
        super("late")
    }

    func grow() {
        super("again")
    }

    @override
    func area(): Float {
        return 1
    }

    @override
    func perimeter(): Float {
        return 1
    }
}

class Plain {
    var n: Int
}

class Child extends Plain {
    constructor() {
        super(n: "one")
    }
}

class Generated extends Child {
    var m: Int = 2
}
const g = Generated(5)
