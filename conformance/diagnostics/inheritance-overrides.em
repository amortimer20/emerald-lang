# Section 10.7: a class shares its names with the classes it extends, and an override matches what it replaces.
class Animal {
    var name: String = "x"
    var _secret: Int = 0
    var Animal.count = 0

    func speak() {
    }

    func _helper() {
    }

    const size: Int {
        return 1
    }

    var weight: Int {
        get {
            return 1
        }
        set {
        }
    }

    func fetch(times: Int, loud: Bool = false): Animal {
        return self
    }
}

class Dog extends Animal {
    func speak() {
    }

    @override
    func bark() {
    }

    @override
    func _helper() {
    }

    var _secret: Int = 1

    @override
    const name: String {
        return "d"
    }

    func size() {
    }

    var count: Int = 0

    @override
    var size: Int {
        get {
            return 2
        }
        set {
        }
    }

    @override
    const weight: String {
        return "heavy"
    }

    @override
    func fetch(count: Int, loud: Bool = true): Int {
        return 1
    }
}

class Loner {
    @override
    func alone() {
    }
}

struct Point {
}
class NotAClass extends Point {
}
class NotAType extends Missing {
}
class Builtin extends Int {
}
class Ouroboros extends Ouroboros {
}
class First extends Second {
}
class Second extends First {
}

# A value that is always there stands in for an optional only when it needs
# nothing done to it, so an Int does not replace a Float?, and an optional
# never replaces a value that is always there.
class Scale {
    func reading(): Float? {
        return nothing
    }

    func unit(): String {
        return "kg"
    }
}

class Precise extends Scale {
    @override
    func reading(): Int {
        return 1
    }

    @override
    func unit(): String? {
        return nothing
    }
}
