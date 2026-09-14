# Section 4.4's narrowing lasts only until an assignment un-proves it, even
# within the very `if` that proved it. The help should say so, rather than
# suggest writing the test the reader is already inside.
class Animal {
}

class Dog extends Animal {
    var tricks: Int = 1
}

var pet: Animal = Dog()
if pet is Dog {
    pet = Animal()
    print(pet.tricks)
}

# Outside any test, the ordinary suggestion still applies.
func describe(animal: Animal) {
    print(animal.tricks)
}
