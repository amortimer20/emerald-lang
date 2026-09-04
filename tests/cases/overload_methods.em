## Methods overload on the same rule functions do (§3.2).
class Greeter {
    func hi(name: String): String { return "hi #{name}" }
    func hi(n: Int): String { return "hi ##{n}" }
    func hi(): String { return "hi there" }
}

var g = Greeter()
print(g.hi("ada"))
print(g.hi(7))
print(g.hi())

## A bare name is a zero-argument call, so it wants the version taking none.
print(g.hi)

## Type-level methods too.
class Make {
    static func tag(text: String): String { return "<#{text}>" }
    static func tag(text: String, n: Int): String { return "<#{text} #{n}>" }
}

print(Make.tag("a"))
print(Make.tag("a", 2))

## An operator is a method, so it overloads as well — which is what lets a vector add
## both another vector and a plain number.
struct Vec with Addable {
    var x: Float
    var y: Float

    func add(other: Vec): Vec { return Vec(self.x + other.x, self.y + other.y) }
    func add(n: Float): Vec { return Vec(self.x + n, self.y + n) }

    func to_string(): String { return "(#{self.x}, #{self.y})" }
}

print((Vec(1.0, 2.0) + Vec(0.5, 0.5)).to_string())
print((Vec(1.0, 2.0) + 10.0).to_string())

## Inherited overloads resolve from the base.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
    func speak(): String { return "#{self.name} makes a noise" }
    func speak(times: Int): String { return "#{self.name} makes #{times} noises" }
}

class Dog extends Animal {
    constructor(name: String) { self.name = name }
}

print(Dog("rex").speak())
print(Dog("rex").speak(3))
