# Section 11.5: an `@override` inherits its base method's registration and never
# repeats `@operator`.
class Meter {
    const length: Int

    constructor(length: Int) {
        self.length = length
    }

    @operator("*")
    func scaled(factor: Int): Meter {
        return Meter(self.length * factor)
    }
}

class Ruler extends Meter {
    constructor(length: Int) {
        super(length)
    }

    @override
    @operator("*")
    func scaled(factor: Int): Meter {
        return Meter(self.length * factor * 2)
    }
}
