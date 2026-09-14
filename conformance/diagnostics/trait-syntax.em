# Section 11.1: what a trait's body can hold.
@abstract
trait Shape extends Base {
}

trait Stored {
    const value: Int = 3

    constructor() {
    }

    func Stored.make() {
    }

    @abstract
    func area(): Float

    func perimeter(): Float {
        return super.perimeter()
    }
}

struct Plain {
    @override
    func f() {
    }
}
