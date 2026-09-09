## <R> is worked out from exactly two shapes and no others: a trailing block whose answer
## decides it, the way map's does, or an ordinary argument written as R itself, the way
## reduce(0) says Int. Both are deliberately narrow.
##
## This is neither. R sits inside a List rather than being the parameter, so reading it
## would mean matching R against the shape of what arrived — a solver, where the two rules
## above are lookups. Refused by name rather than guessed at, because a wrong inference
## costs more than an honest refusal.
##
## This case used to be `weird<R>(x: R)`, which was refused when the only rule was the
## block one. That call now works, and it is what let reduce join the trait.
trait Boxed {
    type Value
    abstract func get(): Value

    func weird<R>(xs: List<R>): R? {
        return xs.first()
    }
}

class IntBox with Boxed {
    type Value = Int
    var v: Int
    constructor(v: Int) { self.v = v }
    func get(): Int { return self.v }
}

var b = IntBox(5)
print(b.weird([3, 4]).or(0))
