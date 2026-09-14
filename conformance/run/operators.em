# Section 11.5: arithmetic and ordering on a user type run named methods of
# the prelude traits it adopts. Section 11.4's `Self` is the adopting type.

# Every arithmetic operator, on a struct. `Self` and the type's own name mean
# the same thing inside it.
struct Vector with Addable, Subtractable, Multipliable, Divisible {
    const x: Float
    const y: Float

    func Vector.zero(): Self {
        return Vector(0, 0)
    }

    @override
    func add(other: Self): Self {
        return Vector(self.x + other.x, self.y + other.y)
    }

    @override
    func subtract(other: Vector): Vector {
        return Vector(self.x - other.x, self.y - other.y)
    }

    @override
    func multiply(other: Self): Self {
        return Vector(self.x * other.x, self.y * other.y)
    }

    @override
    func divide(other: Self): Self {
        return Vector(self.x / other.x, self.y / other.y)
    }
}

var position = Vector.zero() + Vector(1, 2)
print(position)
position += Vector(3, 4)
print(position)
print(position - Vector(1, 1), position * Vector(2, 0.5), position / Vector(8, 3))
# An operator leaves a struct operand as it was, and `==` still compares fields.
const before = position
const moved = position + Vector(1, 1)
print(before == position, moved == Vector(5, 7))
# Precedence is the numbers' precedence.
print(Vector(1, 1) + Vector(2, 2) * Vector(3, 3))

# Ordering, on a class. Every ordering comparison runs `compare`, chains
# included, and `==` is still identity.
class Money with Ordered, Addable {
    const cents: Int

    constructor(cents: Int) {
        self.cents = cents
    }

    @override
    func compare(other: Money): Int {
        return self.cents - other.cents
    }

    @override
    func add(other: Self): Self {
        return Money(self.cents + other.cents)
    }
}

const small = Money(99)
const large = Money(150)
print(small < large, small > large, small <= small, large >= small)
print(small < large < Money(200), small < large < Money(100))
print(small == Money(99), small == small)
print((small + large).cents)

# A subclass inherits the conformance with its base class's types, and an
# operator runs the object's own version of the method.
class Coins extends Money {
    constructor(cents: Int) {
        super(cents)
    }

    @override
    func compare(other: Money): Int {
        print("Coins compares")
        return super.compare(other)
    }
}

print(Coins(5) < Money(10))
const total: Money = Coins(5) + Coins(6)
print(total.cents)

# Inside a trait, `Self` is whichever type adopts it: a trait's default can
# use the operators of the traits it builds on, give back `Self`, and compare
# two values of `Self` with `==`.
trait Doubling with Addable {
    func doubled(): Self {
        return self + self
    }

    func twice_is?(other: Self): Bool {
        return self.doubled() == other
    }
}

struct Count with Doubling {
    const n: Int

    @override
    func add(other: Self): Self {
        return Count(self.n + other.n)
    }
}

const four = Count(2).doubled()
print(four, four.n)
print(Count(2).twice_is?(Count(4)), Count(2).twice_is?(Count(5)))

# A requirement can take and give `Self` in any shape, and a value of a known
# type fills it in: here, a list of `Self`.
trait Splittable {
    func halves(): [Self]
}

struct Length with Splittable, Labelled {
    const metres: Float

    @override
    func halves(): [Length] {
        return [Length(self.metres / 2), Length(self.metres / 2)]
    }
}

const halves = Length(3).halves()
print(halves[0].metres + halves[1].metres)

# A captured method keeps the types of the value it was taken from.
const add_to_position = position.add
print(add_to_position(Vector(10, 10)))

# A value seen through a trait still keeps its `Self`-free members.
func describe(value: Doubling) {
    print("a #{value.type_name}")
}

describe(Count(1))

# An abstract class may adopt an operator's trait and leave the method to its
# subclasses, which take the abstract class's type where the trait has `Self`.
@abstract
class Shape with Addable {
    func area(): Float {
        return 0
    }
}

class Square extends Shape {
    const side: Float

    constructor(side: Float) {
        self.side = side
    }

    @override
    func area(): Float {
        return self.side * self.side
    }

    @override
    func add(other: Shape): Shape {
        return Square(self.side + other.area())
    }
}

const combined: Shape = Square(2) + Square(3)
print(combined.area())

# `Self` narrows with `is` like any other value.
trait Labelled {
    func label(): String {
        if self is Length {
            return "#{self.metres} m"
        }
        return self.type_name
    }
}

struct Tag with Labelled {
}

print(Tag().label(), Length(2).label())
