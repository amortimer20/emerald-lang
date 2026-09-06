# `is` asks what a value actually is, and narrows the name for the branch where the
# answer is yes -- the same machinery the nothing check has always used.

trait Speaker { abstract func speak(): String }

class Animal {
    var name: String
    constructor(name: String) { self.name = name }
    func speak(): String { return "..." }
}

class Dog extends Animal with Speaker {
    constructor(name: String) { super(name) }
    override func speak(): String { return "Woof" }
    func fetch(): String { return "#{self.name} fetches" }
}

var pets: List<Animal> = [Dog("Rex"), Animal("Generic")]

for pet in pets {
    print("#{pet.type_name()}: #{pet.speak()}")

    # Past this check pet is a Dog, so a method Animal does not have is reachable
    if pet is Dog {
        print("  #{pet.fetch()}")
    }

    print("  speaks? #{pet is Speaker}")
}

# type_name answers on every value there is, including the one that is missing
print(42.type_name())
print(3.5.type_name())
print("hi".type_name())
print(true.type_name())
print([1].type_name())
print(["a": 1].type_name())
print((1..3).type_name())

var missing: String? = nothing
print(missing.type_name())
