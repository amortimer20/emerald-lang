class Dog {
    var name: String
    constructor(name: String) { self.name = name }
    static func stray(name: String): Dog { return Dog(name) }
}

print(Dog.stray(99).name)
