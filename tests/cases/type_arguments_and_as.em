# Type arguments at a call site: consuming a generic method, never declaring one.
# §5.3 defers declaring; nothing here introduces a type parameter.

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

for pet in pets {
    print(pet.as<Dog>()?.fetch().or("(not a dog)"))
    print(pet.as<Speaker>()?.speak().or("(silent)"))
}

# The case `is` cannot reach: narrowing records itself on a name, and this is a field,
# so there is nowhere to write the narrower type down.
var kennel = Kennel(Dog("Fido"))
print(kennel.resident.as<Dog>()?.fetch().or("(empty)"))

# A miss gives nothing, handled by the machinery already built for it
var plain: Animal = Animal("Nobody")
print(plain.as<Dog>() == nothing)

# One `<` is still a comparison. §3.1 allows only one comparison in a row, so no valid
# program can mean the other thing -- but the parser still has to hand it back untouched.
var a = 3
var b = 5
print(a < b)
print([3, 1].sort().count() < 5 and 2 > 1)
