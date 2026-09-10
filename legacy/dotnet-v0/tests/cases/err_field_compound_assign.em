## `+=` reads the field before writing it, so it is a use of an unset value rather than a
## way to give it one -- which is what the definite-assignment side already assumed.
class Counter {
    var n: Int

    constructor() {
        self.n += 1
    }
}
