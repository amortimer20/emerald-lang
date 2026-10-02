func ready?(): Int {
    return 1
}

class Parent {
    func available?(): String {
        return "yes"
    }
}

class Child extends Parent {
    @override
    func available?(): String {
        return "still yes"
    }
}

struct Switch {
    const enabled?: String {
        return "no"
    }
}
