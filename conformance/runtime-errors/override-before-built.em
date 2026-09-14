# Section 10.7: a base class's constructor passes the object on, and a subclass's override runs before its fields are set.
func announce(animal: Animal) {
    print(animal.describe())
}

class Animal {
    const name: String

    constructor(name: String) {
        self.name = name
        announce(self)
    }

    func describe(): String {
        return self.name
    }
}

class Dog extends Animal {
    const breed: String

    constructor(name: String, breed: String) {
        super(name)
        self.breed = breed
    }

    @override
    func describe(): String {
        return "#{self.name} the #{self.breed.upper()}"
    }
}

const plain = Animal("Generic")
const rex = Dog("Rex", "collie")
