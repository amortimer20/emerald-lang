# to_string: a type says how it reads as text, and the language calls it for you.

class Money {
    var amount: Int
    constructor(amount: Int) { self.amount = amount }

    func to_string(): String {
        return "$#{self.amount}"
    }
}

# A struct says it the same way a class does.
struct Point {
    var x: Int
    var y: Int

    func to_string(): String {
        return "(#{self.x}, #{self.y})"
    }
}

# So does an enum, which C# cannot do.
enum Suit {
    HEARTS, SPADES

    func to_string(): String {
        return "the #{self.name.lower()}"
    }
}

# A trait can supply the default, and a class below can replace it.
trait Named {
    func to_string(): String {
        return "a #{self.type_name()}"
    }
}

class Animal with Named { }
class Dog extends Animal {
    func to_string(): String { return "a good dog" }
}
class Cat extends Animal { }

# A type that says nothing still prints the plain form.
class Plain {
    var n: Int
    constructor(n: Int) { self.n = n }
}

var m = Money(5)

print(m)
print("I have #{m}")
print(m.to_string())

# Nested, because printing a collection formats each element the same way.
print([m, Money(9)])
print(["fee": m])

print(Point(1, 2))
print(Suit.HEARTS)
print(Animal())
print(Dog())
print(Cat())
print(Plain(3))

# An error is a class with a to_string in the prelude, so this is the same mechanism.
try {
    throw "boom"
}
catch e {
    print(e)
}
