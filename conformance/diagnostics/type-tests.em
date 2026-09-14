# Section 4.4's `is` and `type_name`, used where they cannot be.
class Animal {
    func type_name(): String {
        return "mine"
    }
}
class Dog extends Animal {
    func bark() {
    }
}
func f(animal: Animal) {
    if animal is Dog {
        animal.bark()
    }
    animal.bark()
    if animal is Missing {
    }
    animal.type_name = "Dog"
    if (animal is Dog) or animal.bark() {
    }
}
var shared: Animal = Dog()
func reset() {
    shared = Animal()
}
if shared is Dog {
    shared.bark()
}

# Only a name is narrowed, so a test on a field proves nothing about it.
class Kennel {
    var resident: Animal = Dog()
}
const kennel = Kennel()
if kennel.resident is Dog {
    kennel.resident.bark()
}
