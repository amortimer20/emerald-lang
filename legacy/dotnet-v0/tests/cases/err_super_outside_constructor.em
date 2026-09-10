## super(...) builds an object's base part, which happens once, when it is made.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal {
    func rename() { super("x") }
}
