# Section 10.7: widening a list literal's elements to a shared base only
# applies when the classes actually share one. Two classes with no common
# ancestor still report the mismatch.
class Dog {
    var name: String

    constructor(name: String) {
        self.name = name
    }
}

class Fish {
    var species: String

    constructor(species: String) {
        self.species = species
    }
}

const pets = [Dog("Rex"), Fish("Nemo")]
