# Section 4.4: `is` tests what a value is while the program runs, and proves
# it within the branch where it holds. `type_name` spells a value's own type.

class Animal {
    const name: String

    constructor(name: String) {
        self.name = name
    }
}

class Dog extends Animal {
    var tricks: Int = 0

    constructor(name: String) {
        super(name)
    }

    func fetch(): String {
        self.tricks += 1
        return "#{self.name} fetches"
    }
}

class Puppy extends Dog {
    constructor() {
        super("Pup")
    }
}

class Cat extends Animal {
    constructor() {
        super("Tom")
    }
}

const pets: [Animal] = [Animal("Generic"), Dog("Rex"), Puppy(), Cat()]
for pet in pets {
    print(pet.type_name, pet is Animal, pet is Dog, pet is Puppy, pet is Cat)
    if pet is Dog {
        # `pet` is a `Dog` in here, so its methods are reachable.
        print(pet.fetch())
    }
}

# A test that fails with an early exit proves the rest of the block.
func describe(animal: Animal): String {
    if not (animal is Dog) {
        return "#{animal.name} is not a dog"
    }
    return "#{animal.name} knows #{animal.tricks} trick(s)"
}
print(describe(pets[1]), "/", describe(pets[3]))

# `and` and `or` check their right side knowing how the left one went, for
# type tests and for `nothing` alike.
func first_trick(maybe: Animal?): String {
    if maybe != nothing and maybe is Dog and maybe.tricks > 0 {
        return maybe.fetch()
    }
    if maybe == nothing or maybe.name == "" {
        return "no one"
    }
    return "#{maybe.name} knows no tricks"
}
print(first_trick(pets[1]), "/", first_trick(pets[0]), "/", first_trick(nothing))

# An optional is `Nothing` when it is empty.
const missing: Dog? = nothing
print(missing is Dog, missing is Nothing, missing.type_name)

# Every value has a type name, spelled as the program would write its type.
print(1.type_name, 2.5.type_name, "hi".type_name, true.type_name, nothing.type_name)
print([1, 2].type_name, ["a": 1].type_name, (1, "one").type_name)
const pair: (Animal, Int) = (Cat(), 1)
print(pair.type_name, pair is (Cat, Int), pair is (Dog, Int))
const twice: func(Int): Int = { n => n * 2 }
print(twice.type_name, twice is func(Int): Int)
var count: Int? = 3
print(count.type_name, count is Int, count is Float)

# The value is evaluated once, even when the answer is known in advance.
func loud(): Int {
    print("evaluated")
    return 1
}
print(loud() is Int)

# A block keeps a narrowing made outside it for a variable that is never given
# a new value, and a test inside a block narrows there whatever happens outside.
var steady: Animal? = Dog("Steady")
if steady is Dog {
    const count_tricks = { => steady.tricks }
    print(count_tricks())
}

var current: Animal = Dog("Current")
const report = { =>
    if current is Dog {
        print("#{current.name} knows #{current.tricks} trick(s)")
    } else {
        print("#{current.name} is not a dog")
    }
}
report()
current = Cat()
report()
