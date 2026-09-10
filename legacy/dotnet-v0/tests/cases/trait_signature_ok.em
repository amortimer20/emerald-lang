## An unannotated requirement asks for nothing in particular and anything answers it,
## which is what makes the operator traits work: the prelude declares `abstract func
## add(other)` and a type's own add takes and returns itself.
trait Sized {
    abstract func size(dimension)
}

class Box with Sized {
    func size(dimension: Int): Int { return dimension * 2 }
}

print(Box().size(4))

struct Money with Addable, Equatable, Ordered {
    var cents: Int

    func add(other: Money): Money { return Money(self.cents + other.cents) }

    func equals?(other: Money): Bool { return self.cents == other.cents }

    func compare(other: Money): Int { return self.cents - other.cents }
}

print((Money(120) + Money(30)).cents)
print(Money(1) < Money(2))
print(Money(5) == Money(5))
