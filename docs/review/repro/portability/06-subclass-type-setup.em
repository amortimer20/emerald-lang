# 10.4/14.1: type-level fields set up "the first time the type is constructed".
# Constructing a Dog runs Animal's constructor, but Animal's type-level fields
# are not set up until an Animal itself is built.
func note(label: String): Int {
    print("  setting up #{label}")
    return 0
}

class Animal {
    var Animal.made = note("Animal.made")
    var name: String = "pet"
}

class Dog extends Animal {
    var Dog.dogs = note("Dog.dogs")
}

print("constructing a Dog")
const dog = Dog()
print("constructing an Animal")
const animal = Animal()
print("done")
