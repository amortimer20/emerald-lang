## Method calls are checked the same way function calls are — arity, defaults, and
## argument types, on instance methods, inherited ones, and statics.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }

    func speak(volume: Int): String {
        return "#{self.name} at #{volume}"
    }
}

class Dog extends Animal {

    func fed(times: Int, treat: String = "biscuit"): String {
        return "#{self.name} ate #{times} #{treat}"
    }

    static func stray(name: String): Dog {
        return Dog(name)
    }
}

var d = Dog("rex")
print(d.speak(3))
print(d.fed(2))
print(d.fed(2, "bone"))
print(Dog.stray("ghost").name)

## Bare access is still a zero-argument call, and a predicate still reads as one.
class Box {
    var n: Int
    constructor(n: Int) { self.n = n }
    func show(): Int { return self.n }
    func empty?(): Bool { return self.n == 0 }
}

print(Box(0).show())
print(Box(0).empty?())
