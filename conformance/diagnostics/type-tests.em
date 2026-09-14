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
