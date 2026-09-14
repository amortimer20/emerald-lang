# Section 11.1 and 11.2: what a type adopting a trait must supply, and how traits combine.
trait Named {
    const name: String
    var nickname: String

    func greet(): String

    func introduction(): String {
        return self._prefix() + self.name
    }

    func _prefix(): String {
        return "I am "
    }
}

trait Loud {
    func introduction(): String {
        return "HEY"
    }

    const name: Int
}

struct Missing with Named {
}

struct WrongTypes with Named {
    const name: Int
    const nickname: String = ""

    @override
    func greet(other: String): Int {
        return 1
    }
}

struct Forgot with Named {
    const name: String = "a"
    var nickname: String = "b"

    func greet(): String {
        return "hi"
    }

    func _prefix(): String {
        return "mine"
    }
}

class Both with Named, Loud {
    const name: String = "x"
    var nickname: String = "y"

    @override
    func greet(): String {
        return "hi"
    }
}

@abstract
class Later with Named {
}

struct Point {
}

class Pet with Point {
}

class Animal {
}

struct Tagged with Animal, Named, Named {
}

trait Loop with Loop {
}


func use(named: Named) {
    const other = Named()
    print(named == named)
    print(named._prefix())
    named.nickname = "z"
}

const c = Named.greet(Forgot())

# A trait's private helper is its own: neither a trait built on it nor a type
# adopting it can reach it.
trait Tidy {
    func _sweep(): String {
        return "swept"
    }

    func tidy(): String {
        return self._sweep()
    }
}

trait VeryTidy with Tidy {
    func polish(): String {
        return self._sweep()
    }
}

struct Room with VeryTidy {
    func clean(): String {
        return self._sweep()
    }
}

print(Room()._sweep())

# Running one trait's default is a call, not a value to take.
const sweeper = Tidy.tidy
