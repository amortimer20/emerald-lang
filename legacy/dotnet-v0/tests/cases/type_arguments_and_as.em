# `is` and `as` are one question with two answers. `is` narrows a name; `as` gives the
# value, for the places narrowing cannot reach -- a field is not a name.

trait Speaker { abstract func speak(): String }

class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal with Speaker {
    constructor(name: String) { super(name) }
    func speak(): String { return "Woof" }
    func fetch(): String { return "#{self.name} fetches" }
}

class Kennel {
    var resident: Animal
    constructor(a: Animal) { self.resident = a }
}

var pets: List<Animal> = [Dog("Rex"), Animal("Generic")]

# The ordinary way to ask, and the one a beginner writes
for pet in pets {
    if pet is Dog {
        print(pet.fetch())
    }
    else {
        print("not a dog")
    }
}

# A field has nowhere to record a narrowing, so it takes the value form instead
var kennel = Kennel(Dog("Fido"))
var resident = kennel.resident as Dog
if resident != nothing {
    print(resident.fetch())
}

# A miss is nothing, handled by the machinery already built for it
var plain: Animal = Animal("Nobody")
print(plain as Dog == nothing)
print((plain as Speaker) == nothing)

# Traits work on both sides
var rex: Animal = Dog("Rex")
print((rex as Speaker)?.speak().or("(silent)"))

# One `<` is still a comparison
var a = 3
var b = 5
print(a < b)
print([3, 1].sort().count() < 5 and 2 > 1)
