## A name starting with _ belongs to its type and to anything that extends it. §3.2 has
## called this compiler-enforced since the document was written; it was never built, and
## the gap surfaced only when a worked example claimed it in prose.
class Animal {
    var _secret: String = "shh"

    func _whisper(): String { return self._secret }

    func speak(): String { return "..." }
}

class Dog extends Animal {
    ## A subclass may: _ collapses private and protected into one level.
    override func speak(): String { return self._whisper() }
}

print(Dog().speak())

class Money {
    var _cents: Int

    constructor(cents: Int) { self._cents = cents }

    ## Another instance of the same class may, which is what makes equality writable.
    func equals?(other: Money): Bool { return self._cents == other._cents }
}

print(Money(5).equals?(Money(5)))

class Counter {
    static var _made: Int = 0

    static func make(): Counter {
        Counter._made += 1
        return Counter()
    }

    static func count(): Int { return Counter._made }
}

Counter.make()
Counter.make()
print(Counter.count())
