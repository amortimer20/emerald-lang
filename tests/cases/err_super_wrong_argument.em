## The call is checked like any other: it is a constructor with parameters.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal {
    var breed: String
    constructor(breed: String) {
        super(42)
        self.breed = breed
    }
}
