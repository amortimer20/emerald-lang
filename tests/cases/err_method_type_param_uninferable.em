## <R> can only be worked out from the one shape map's own R is: a trailing block whose
## answer decides it. Anything else is refused by name rather than silently mistyped.
trait Boxed {
    type Value
    abstract func get(): Value

    func weird<R>(x: R): R {
        return x
    }
}

class IntBox with Boxed {
    type Value = Int
    var v: Int
    constructor(v: Int) { self.v = v }
    func get(): Int { return self.v }
}

var b = IntBox(5)
print(b.weird(3))
